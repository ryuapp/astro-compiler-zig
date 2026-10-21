const std = @import("std");
const native = @import("native_parser.zig");
const raw = @import("yuku_tree.zig");
const types = @import("astro_types.zig");
const yuku = @import("parser");
const Value = std.json.Value;
const Allocator = std.mem.Allocator;

pub const ParseResult = struct { ast: Value, diagnostics: []const types.AstroDiagnostic };

/// Holds one parsed document before exporting its owned JSON snapshot.
/// Initialize in place and supply an arena for the document and exported values.
pub const ParseSession = struct {
    document: native.Document,
    body_parser: yuku.Parser,
    tree: yuku.ast.Tree,
    active_document: *native.Document,
    pending: std.AutoHashMapUnmanaged(yuku.ast.NodeIndex, @import("embedded_markup.zig").Pending),
    pending_epoch: u64,
    candidates: std.ArrayList(*native.Document),
    candidate_depth: u16,
    connect_stack: std.ArrayList(yuku.ast.NodeIndex),
    connect_seen: std.AutoHashMapUnmanaged(yuku.ast.NodeIndex, void),

    pub fn init(self: *ParseSession, allocator: Allocator, source: []const u8, editor_mode: bool) !void {
        return self.initMode(allocator, source, .{ .editor_mode = editor_mode });
    }

    pub fn initForTransform(self: *ParseSession, allocator: Allocator, source: []const u8) !void {
        return self.initMode(allocator, source, .{ .transform_mode = true });
    }

    pub fn initForStyles(self: *ParseSession, allocator: Allocator, source: []const u8) !void {
        return self.initMode(allocator, source, .{ .transform_mode = true, .standard_frontmatter_jsx = true });
    }

    fn initMode(self: *ParseSession, allocator: Allocator, source: []const u8, mode: struct { editor_mode: bool = false, transform_mode: bool = false, standard_frontmatter_jsx: bool = false }) !void {
        if (source.len > std.math.maxInt(u32)) return error.SourceTooLarge;
        self.pending = .empty;
        self.pending_epoch = 0;
        self.candidates = .empty;
        self.candidate_depth = 0;
        self.connect_stack = .empty;
        self.connect_seen = .empty;
        self.document.init(allocator, source);
        self.document.session = self;
        self.active_document = &self.document;
        self.document.editor_mode = mode.editor_mode;
        self.document.preserve_script_trivia = mode.transform_mode;
        self.document.collect_tokens = !mode.transform_mode;
        self.document.standard_frontmatter_jsx = mode.standard_frontmatter_jsx;
        self.tree = yuku.ast.Tree.initInArena(allocator, source);
        const options = self.document.options(false);
        self.tree.source_type = options.source_type;
        self.tree.lang = options.lang;
        try self.body_parser.initInTree(&self.tree, options, .{ .start = 0, .end = 0 });
        errdefer if (self.body_parser.initialized) self.body_parser.deinit();
        const estimated_nodes = @min(16_384, @max(256, source.len / 16));
        try self.tree.nodes.ensureTotalCapacity(allocator, estimated_nodes);
        try self.tree.extras.ensureTotalCapacity(allocator, estimated_nodes);
        self.document.body_parser = &self.body_parser;
        try self.document.parse();
        _ = try self.body_parser.finish(.null);
        const root = try @import("embedded_markup.zig").documentRoot(self);
        try self.tree.finalize(root, .{ .attach_comments = false });
        const roots = self.document.embedded_roots.items;
        std.sort.heap(yuku.ast.NodeIndex, roots, &self.tree, struct {
            fn before(tree: *const yuku.ast.Tree, first: yuku.ast.NodeIndex, second: yuku.ast.NodeIndex) bool {
                const a = tree.span(first);
                const b = tree.span(second);
                if (a.start == b.start) return a.end > b.end;
                return a.start < b.start;
            }
        }.before);
        var count: usize = 0;
        for (roots) |index| {
            if (count > 0 and roots[count - 1] == index) continue;
            roots[count] = index;
            count += 1;
        }
        self.document.embedded_roots.shrinkRetainingCapacity(count);
    }

    pub fn exportResult(self: *ParseSession) !ParseResult {
        return exportDocument(self.document.allocator, self.document.source, &self.document, &self.tree);
    }

    pub fn deinit(self: *ParseSession) void {
        self.tree.deinit();
    }
};

/// Parse Astro syntax and retain complete Yuku JS/TS payloads and byte offsets.
/// The caller supplies an arena whose lifetime covers the returned values.
pub fn parse(allocator: Allocator, source: []const u8) !ParseResult {
    return parseWithMode(allocator, source, false);
}

pub fn parseForTsx(allocator: Allocator, source: []const u8) !ParseResult {
    return parseWithMode(allocator, source, true);
}

fn parseWithMode(allocator: Allocator, source: []const u8, editor_mode: bool) !ParseResult {
    var session: ParseSession = undefined;
    try session.init(allocator, source, editor_mode);
    defer session.deinit();
    return session.exportResult();
}

fn exportDocument(allocator: Allocator, source: []const u8, document: *native.Document, tree: *const yuku.ast.Tree) !ParseResult {
    var ast = raw.object(allocator);
    try raw.put(allocator, &ast, "type", .{ .string = "AstroRoot" });
    try raw.put(allocator, &ast, "start", .{ .integer = 0 });
    try raw.put(allocator, &ast, "end", .{ .integer = @intCast(source.len) });
    try raw.put(allocator, &ast, "tree", try document.captureJavaScript(tree));
    var frontmatter: Value = .null;
    if (document.frontmatter) |region| {
        frontmatter = raw.object(allocator);
        try raw.put(allocator, &frontmatter, "start", .{ .integer = region.start });
        try raw.put(allocator, &frontmatter, "end", .{ .integer = region.end });
        try raw.put(allocator, &frontmatter, "source", .{ .string = region.source });
        try raw.put(allocator, &frontmatter, "root", try raw.value(allocator, document.frontmatter_root.?));
    }
    try raw.put(allocator, &ast, "frontmatter", frontmatter);
    var nodes = raw.array(allocator);
    for (document.nodes.items, 0..) |node, index| {
        var exported = try raw.nativeValue(allocator, node);
        try raw.put(allocator, &exported, "javascript", try raw.value(allocator, document.javascript_roots.items[index]));
        try raw.put(allocator, &exported, "typeArguments", try raw.value(allocator, document.type_argument_roots.items[index]));
        try nodes.array.append(exported);
    }
    var template = raw.object(allocator);
    try raw.put(allocator, &template, "start", .{ .integer = @intCast(document.template_start) });
    try raw.put(allocator, &template, "end", .{ .integer = @intCast(source.len) });
    try raw.put(allocator, &template, "source", .{ .string = source[document.template_start..] });
    try raw.put(allocator, &template, "nodes", nodes);
    try raw.put(allocator, &template, "rootIds", try raw.value(allocator, document.roots.items));
    try raw.put(allocator, &ast, "template", template);
    // These include tag trivia and decoded values from the shared Yuku tree.
    var comments = raw.array(allocator);
    std.mem.sort(Value, document.js_comments.items, {}, commentLessThan);
    var previous_end: ?i64 = null;
    var previous_start: ?i64 = null;
    for (document.js_comments.items) |comment| {
        const span = comment.object.get("span").?;
        const start = span.object.get("start").?.integer;
        const end = span.object.get("end").?.integer;
        if (previous_start == start and previous_end == end) continue;
        try comments.array.append(comment);
        previous_start = start;
        previous_end = end;
    }
    try raw.put(allocator, &ast, "comments", comments);
    return .{ .ast = ast, .diagnostics = document.diagnostics.items };
}

fn commentSpanLessThan(_: void, left: yuku.ast.Comment, right: yuku.ast.Comment) bool {
    return left.span.start < right.span.start;
}

fn commentLessThan(_: void, left: Value, right: Value) bool {
    return left.object.get("span").?.object.get("start").?.integer <
        right.object.get("span").?.object.get("start").?.integer;
}
