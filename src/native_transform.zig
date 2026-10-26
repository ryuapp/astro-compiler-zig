const std = @import("std");
const yuku = @import("parser");
const parse = @import("astro_parse.zig");
const types = @import("astro_types.zig");
const styles = @import("native_styles.zig");
const css = @import("transform_css.zig");
const text = @import("tsx_text.zig");
const analysis = @import("tsx_analysis.zig");
const maps = @import("transform_sourcemap.zig");
const Allocator = std.mem.Allocator;
const Index = yuku.ast.NodeIndex;
const Node = types.AstroNode;
const Attr = types.AstroAttribute;
const Error = anyerror;

pub const Options = struct {
    filename: ?[]const u8 = null,
    normalized_filename: ?[]const u8 = null,
    internal_url: ?[]const u8 = null,
    sourcemap: ?[]const u8 = null,
    astro_global_args: ?[]const u8 = null,
    compact: ?[]const u8 = null,
    scoped_style_strategy: ?[]const u8 = null,
    result_scoped_slot: bool = false,
    transitions_animation_url: ?[]const u8 = null,
    annotate_source_file: bool = false,
    inline_component_assets: bool = false,
    resolve_path_provided: bool = false,
    preprocessed_styles: ?[]const ?[]const u8 = null,
};
pub const Component = struct { export_name: []const u8, local_name: []const u8, specifier: []const u8, resolved_path: []const u8 };
pub const Script = struct { type: []const u8, code: ?[]const u8 = null, src: ?[]const u8 = null };
pub const Result = struct {
    code: []const u8 = "",
    /// Raw VLQ mappings; the JS wrapper serializes and embeds the source map.
    map: []const u8 = "",
    scope: []const u8 = "",
    css: []const []const u8 = &.{},
    scripts: []const Script = &.{},
    hydrated_components: []const Component = &.{},
    client_only_components: []const Component = &.{},
    server_components: []const Component = &.{},
    contains_head: bool = false,
    propagation: bool = false,
    style_error: []const []const u8 = &.{},
    diagnostics: []const types.AstroDiagnostic = &.{},
};
const Import = struct { local: []const u8, exported: []const u8, specifier: []const u8, namespace: bool = false };
const Module = struct { root: Index, specifier: []const u8, namespace: ?usize = null, skip: bool = false };
const Helpers = enum { Fragment, render, createAstro, createComponent, renderComponent, renderHead, maybeRenderHead, unescapeHTML, renderSlot, mergeSlots, addAttribute, spreadAttributes, defineStyleVars, defineScriptVars, renderTransition, createTransitionScope, renderScript, templateEnter, templateExit, createMetadata };

pub fn transform(allocator: Allocator, source: []const u8, options: Options) !Result {
    var session: parse.ParseSession = undefined;
    try session.initForTransform(allocator, source);
    defer session.deinit();
    for (session.document.diagnostics.items) |item| if (text.eql(item.severity, "error")) return .{ .diagnostics = session.document.diagnostics.items };
    var emitter: Emitter = .{ .allocator = allocator, .source = source, .session = &session, .options = options, .hash = try scopeHash(allocator, options.normalized_filename orelse options.filename orelse "<stdin>", source) };
    try emitter.scan();
    return emitter.generate();
}

const Emitter = struct {
    allocator: Allocator,
    source: []const u8,
    session: *const parse.ParseSession,
    options: Options,
    hash: []const u8,
    out: std.ArrayList(u8) = .empty,
    mappings: std.ArrayList(maps.Copy) = .empty,
    anchors: std.ArrayList(maps.Anchor) = .empty,
    helpers: std.EnumSet(Helpers) = .{},
    imports: std.ArrayList(Import) = .empty,
    modules: std.ArrayList(Module) = .empty,
    exports: std.ArrayList(Index) = .empty,
    statements: std.ArrayList(Index) = .empty,
    style_ids: []const u32 = &.{},
    css_text: std.ArrayList([]const u8) = .empty,
    vars: std.ArrayList(Attr) = .empty,
    scripts: std.ArrayList(Script) = .empty,
    script_ids: std.ArrayList(u32) = .empty,
    hydrated: std.ArrayList(Component) = .empty,
    hydrated_names: std.ArrayList([]const u8) = .empty,
    client_only: std.ArrayList(Component) = .empty,
    server: std.ArrayList(Component) = .empty,
    directives: std.ArrayList([]const u8) = .empty,
    diagnostics: std.ArrayList(types.AstroDiagnostic) = .empty,
    uses_astro: bool = false,
    has_await: bool = false,
    transitions: bool = false,
    scoped: bool = false,
    explicit_head: bool = false,
    head_inserted: bool = false,
    in_head: bool = false,
    raw_depth: usize = 0,
    skip_slot: bool = false,
    transition_counter: usize = 0,
    defined_vars_injected: bool = false,
    nesting: usize = 0,

    fn get(self: *const Emitter, id: u32) *const Node {
        return &self.session.document.nodes.items[id];
    }
    fn put(self: *Emitter, value: []const u8) !void {
        try self.out.appendSlice(self.allocator, value);
    }
    fn fmt(self: *Emitter, comptime format: []const u8, args: anytype) !void {
        var writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.out);
        defer self.out = writer.toArrayList();
        writer.writer.print(format, args) catch return error.OutOfMemory;
    }
    fn string(self: *Emitter, value: []const u8) !void {
        var writer: std.Io.Writer.Allocating = .fromArrayList(self.allocator, &self.out);
        defer self.out = writer.toArrayList();
        std.json.Stringify.value(value, .{}, &writer.writer) catch return error.OutOfMemory;
    }
    fn decoded(self: *Emitter, value: []const u8) ![]const u8 {
        if (std.mem.indexOfScalar(u8, value, '&') == null) return value;
        return text.decodeEntities(self.allocator, value);
    }
    fn helper(self: *Emitter, which: Helpers) !void {
        self.helpers.insert(which);
        if (which != .Fragment) try self.put("$$");
        try self.put(@tagName(which));
    }
    fn copy(self: *Emitter, start: usize, end: usize) !void {
        if (end <= start) return;
        try self.mappings.append(self.allocator, .{ .generated = @intCast(self.out.items.len), .original = @intCast(start), .length = @intCast(end - start) });
        try self.put(self.source[start..end]);
    }
    fn mark(self: *Emitter, original: u32) !void {
        try self.mappings.append(self.allocator, .{ .generated = @intCast(self.out.items.len), .original = original, .length = 0 });
    }
    fn anchor(self: *Emitter, id: Index, point: ?u32, multiline: bool) !void {
        if (id == .null or self.options.sourcemap == null) return;
        const span = self.session.tree.span(id);
        try self.anchors.append(self.allocator, .{ .start = span.start, .end = span.end, .point = point orelse span.start, .multiline = multiline });
    }
    fn expressionAnchors(self: *Emitter, id: Index, point: ?u32, depth: usize) Error!void {
        if (id == .null or depth > 256 or self.options.sourcemap == null) return;
        try self.anchor(id, point, false);
        switch (self.data(id)) {
            .call_expression => |v| {
                try self.expressionAnchors(v.callee, null, depth + 1);
                for (self.session.tree.extra(v.arguments)) |arg| try self.expressionAnchors(arg, null, depth + 1);
            },
            .member_expression => |v| {
                try self.expressionAnchors(v.object, null, depth + 1);
                if (v.computed) try self.expressionAnchors(v.property, null, depth + 1);
            },
            .arrow_function_expression => |v| {
                try self.anchor(v.params, null, false);
                if (self.data(v.body) == .function_body) {
                    for (self.session.tree.extra(self.data(v.body).function_body.body)) |stmt| {
                        try self.anchor(stmt, null, true);
                        if (self.data(stmt) == .return_statement) try self.expressionAnchors(self.data(stmt).return_statement.argument, null, depth + 1);
                    }
                } else try self.expressionAnchors(v.body, null, depth + 1);
            },
            .function => |v| {
                // A function body must retain its own source lines rather than
                // inherit the containing expression's single starting point.
                try self.anchor(v.body, null, true);
                try self.nestedFunctionAnchors(v.params, depth + 1);
                try self.nestedFunctionAnchors(v.body, depth + 1);
            },
            .conditional_expression => |v| {
                try self.expressionAnchors(v.@"test", null, depth + 1);
                try self.expressionAnchors(v.consequent, null, depth + 1);
                try self.expressionAnchors(v.alternate, null, depth + 1);
            },
            .logical_expression => |v| {
                try self.expressionAnchors(v.left, null, depth + 1);
                try self.expressionAnchors(v.right, null, depth + 1);
            },
            .array_expression => |v| for (self.session.tree.extra(v.elements)) |item| {
                try self.expressionAnchors(item, null, depth + 1);
            },
            .parenthesized_expression => |v| try self.expressionAnchors(v.expression, null, depth + 1),
            else => try self.nestedFunctionAnchors(id, depth + 1),
        }
    }
    fn nestedFunctionAnchors(self: *Emitter, id: Index, depth: usize) Error!void {
        if (id == .null or depth > 256) return;
        const node_data = self.data(id);
        if (node_data == .function or node_data == .arrow_function_expression) return self.expressionAnchors(id, null, depth + 1);
        switch (node_data) {
            inline else => |value| if (@typeInfo(@TypeOf(value)) == .@"struct") {
                inline for (@import("meta").fields(@TypeOf(value))) |field| {
                    if (field.type == Index) try self.nestedFunctionAnchors(@field(value, field.name), depth + 1);
                    if (field.type == yuku.ast.IndexRange) for (self.session.tree.extra(@field(value, field.name))) |child| try self.nestedFunctionAnchors(child, depth + 1);
                }
            },
        }
    }
    fn template(self: *Emitter, source: []const u8) !void {
        var start: usize = 0;
        for (source, 0..) |c, i| {
            if (c == '\\' or c == '`' or (c == '$' and i + 1 < source.len and source[i + 1] == '{')) {
                try self.put(source[start..i]);
                try self.put("\\");
                start = i;
            }
        }
        try self.put(source[start..]);
    }
    fn js(self: *Emitter, start: usize, end: usize) Error!void {
        const roots = self.session.document.embedded_roots.items;
        var low: usize = 0;
        var high = roots.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.session.tree.span(roots[middle]).start < start) low = middle + 1 else high = middle;
        }
        var pos = start;
        for (roots[low..]) |root| {
            const span = self.session.tree.span(root);
            if (span.start >= end) break;
            if (span.start < pos or span.end > end) continue;
            try self.copy(pos, span.start);
            try self.helper(.render);
            try self.put("`");
            try self.node(self.session.document.embedded.get(root).?, false);
            try self.put("`");
            pos = span.end;
        }
        try self.copy(pos, end);
    }
    fn attrExpr(self: *Emitter, item: Attr) Error!void {
        if (text.eql(item.kind, "boolean")) try self.put("true") else if ((text.eql(item.kind, "quoted") or text.eql(item.kind, "unquoted"))) try self.string(try self.decoded(item.value orelse "")) else {
            const start = item.value_start orelse item.start;
            const end = item.value_end orelse item.end;
            if (item.expression) |expression| if (self.session.document.javascript_roots.items[expression]) |root| {
                try self.expressionAnchors(@fromBackingInt(@intCast(root)), null, 0);
            };
            if (text.trim(self.source[start..end]).len == 0) try self.put("void 0") else try self.js(start, end);
        }
    }
    fn astName(self: *Emitter, id: Index) []const u8 {
        const a: analysis.Analysis = .{ .allocator = self.allocator, .source = self.source, .tree = &self.session.tree };
        return a.name(id);
    }
    fn attributeName(self: *Emitter, item: Attr) []const u8 {
        if (text.eql(item.kind, "shorthand")) {
            if (item.expression) |id| if (self.session.document.javascript_roots.items[id]) |root| {
                const name = self.astName(@fromBackingInt(@intCast(root)));
                if (name.len > 0) return name;
            };
        }
        return item.name orelse item.value orelse "";
    }
    fn propExpr(self: *Emitter, item: Attr) Error!void {
        if (!text.eql(item.kind, "quoted") and !text.eql(item.kind, "unquoted")) return self.attrExpr(item);
        try self.propString(try self.decoded(item.value orelse ""));
    }
    // Adapted from Astro's escape_double_quotes_keeping_escapes in
    // crates/astro_codegen/src/printer/escape.rs.
    // MIT terms are in LICENSE. Escape-table attribution is beside jsEscapeLength.
    fn propString(self: *Emitter, source: []const u8) !void {
        try self.put("\"");
        var i: usize = 0;
        var start: usize = 0;
        while (i < source.len) : (i += 1) {
            const c = source[i];
            if (c != '\\' and c != '"' and c != '\n' and c != '\r') continue;
            try self.put(source[start..i]);
            if (c == '\\') {
                const length = jsEscapeLength(source[i + 1 ..]);
                if (length > 0) {
                    try self.put(source[i .. i + length + 1]);
                    i += length;
                    start = i + 1;
                    continue;
                }
                try self.put("\\\\");
            } else if (c == '"') try self.put("\\\"") else if (c == '\n') try self.put("\\n") else try self.put("\\r");
            start = i + 1;
        }
        try self.put(source[start..]);
        try self.put("\"");
    }
    fn data(self: *Emitter, id: Index) yuku.ast.NodeData {
        return self.session.tree.data(id);
    }
    fn referenced(self: *Emitter, local: []const u8) bool {
        for (self.session.tree.nodes.items(.data)) |value| if (value == .identifier_reference and text.eql(self.session.tree.string(value.identifier_reference.name), local)) return true;
        for (self.session.document.nodes.items) |node_value| if (text.eql(node_value.type_name, "Component") and styles.attribute(node_value, "client:only") == null) {
            const name = node_value.name orelse "";
            const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
            if (text.eql(name[0..dot], local)) return true;
        };
        return false;
    }
    fn importClientOnly(self: *Emitter, local: []const u8) bool {
        if (self.referenced(local)) return false;
        for (self.session.document.nodes.items) |node_value| if (styles.attribute(node_value, "client:only") != null) {
            const name = node_value.name orelse "";
            if (text.eql(local, name[0 .. std.mem.indexOfScalar(u8, name, '.') orelse name.len])) return true;
        };
        return false;
    }
    fn metadata(self: *Emitter, name: []const u8) !?Component {
        const dot = std.mem.indexOfScalar(u8, name, '.') orelse name.len;
        for (self.imports.items) |item| if (text.eql(item.local, name[0..dot])) {
            const exported = if (dot == name.len) item.exported else if (item.namespace) name[dot + 1 ..] else if (text.eql(item.exported, "default")) try std.fmt.allocPrint(self.allocator, "default.{s}", .{name[dot + 1 ..]}) else name;
            return .{ .export_name = exported, .local_name = name, .specifier = item.specifier, .resolved_path = try self.resolve(item.specifier) };
        };
        return null;
    }
    fn resolve(self: *Emitter, specifier: []const u8) ![]const u8 {
        if (self.options.filename) |filename| {
            if (!text.eql(filename, "<stdin>") and std.mem.startsWith(u8, specifier, ".")) {
                const slash = std.mem.lastIndexOfScalar(u8, filename, '/');
                const dir = if (slash) |n| filename[0..if (n == 0) 1 else n] else "";
                const joined = if (dir.len == 0) specifier else try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ dir, specifier });
                var parts: std.ArrayList([]const u8) = .empty;
                if (joined.len > 0 and joined[0] == '/') try parts.append(self.allocator, "/");
                var it = std.mem.splitScalar(u8, joined, '/');
                while (it.next()) |part| {
                    if (text.eql(part, ".") or part.len == 0) continue;
                    if (text.eql(part, "..") and parts.items.len > 0 and !text.eql(parts.items[parts.items.len - 1], "..")) {
                        _ = parts.pop();
                    } else try parts.append(self.allocator, part);
                }
                const absolute = parts.items.len > 0 and text.eql(parts.items[0], "/");
                const result = try std.mem.join(self.allocator, "/", if (absolute) parts.items[1..] else parts.items);
                return if (absolute) try std.fmt.allocPrint(self.allocator, "/{s}", .{result}) else result;
            }
        }
        return specifier;
    }
    fn addComponent(self: *Emitter, list: *std.ArrayList(Component), name: []const u8) !void {
        for (list.items) |item| if (text.eql(item.local_name, name)) return;
        if (try self.metadata(name)) |item| try list.append(self.allocator, item);
    }
    fn scan(self: *Emitter) !void {
        try self.diagnostics.appendSlice(self.allocator, self.session.document.diagnostics.items);
        const tree = &self.session.tree;
        for (tree.nodes.items(.data)) |value| switch (value) {
            .identifier_reference => |v| if (text.eql(tree.string(v.name), "Astro")) {
                self.uses_astro = true;
            },
            .await_expression => self.has_await = true,
            .variable_declaration => |v| if (v.kind == .await_using) {
                self.has_await = true;
            },
            .for_of_statement => |v| if (v.await) {
                self.has_await = true;
            },
            else => {},
        };
        if (self.session.document.frontmatter_root) |root| {
            for (tree.extra(self.data(@fromBackingInt(@intCast(root))).program.body)) |id| {
                const value = self.data(id);
                if (value == .import_declaration) {
                    const decl = value.import_declaration;
                    const specifier = self.astName(decl.source);
                    var all_only = decl.specifiers.len > 0;
                    var all_unused = decl.specifiers.len > 0;
                    for (tree.extra(decl.specifiers)) |spec| {
                        const spec_data = self.data(spec);
                        const local = self.astName(analysis.index(spec_data, "local"));
                        const exported = if (spec_data == .import_namespace_specifier) "*" else if (spec_data == .import_default_specifier) "default" else self.astName(analysis.index(spec_data, "imported"));
                        try self.imports.append(self.allocator, .{ .local = local, .exported = exported, .specifier = specifier, .namespace = spec_data == .import_namespace_specifier });
                        all_only = all_only and self.importClientOnly(local);
                        all_unused = all_unused and !self.referenced(local);
                    }
                    const is_type = @hasField(@TypeOf(decl), "import_kind") and decl.import_kind == .type;
                    var namespace: ?usize = null;
                    if (!is_type and !all_only and !(decl.specifiers.len == 0 and cssSpecifier(specifier))) {
                        var count: usize = 1;
                        for (self.modules.items) |module| if (module.namespace != null) {
                            count += 1;
                        };
                        namespace = count;
                    }
                    try self.modules.append(self.allocator, .{ .root = id, .specifier = specifier, .namespace = namespace, .skip = all_only or all_unused or is_type });
                } else if (value == .export_named_declaration or value == .export_all_declaration or value == .export_default_declaration) {
                    try self.exports.append(self.allocator, id);
                } else try self.statements.append(self.allocator, id);
            }
        }
        self.style_ids = try styles.collect(self.allocator, &self.session.document);
        for (self.style_ids, 0..) |id, i| {
            const node_value = self.get(id);
            const global = styles.attribute(node_value, "is:global") != null;
            if (!global or styles.attribute(node_value, "define:vars") != null) self.scoped = true;
            if (styles.attribute(node_value, "define:vars")) |attr| try self.vars.append(self.allocator, attr);
            var content = node_value.value orelse "";
            if (self.options.preprocessed_styles) |processed| if (i < processed.len) {
                if (processed[i]) |value| content = value;
            };
            content = text.trim(content);
            if (content.len == 0) continue;
            try self.css_text.append(self.allocator, if (global) content else try css.scope(self.allocator, content, self.hash, self.strategy()));
        }
        for (self.session.document.roots.items) |id| try self.scanNode(id, false, 0);
    }
    fn scanNode(self: *Emitter, id: u32, blocked: bool, depth: usize) Error!void {
        if (depth >= 256) return error.CodegenNestingTooDeep;
        const node_value = self.get(id);
        const name = node_value.name orelse "";
        if (std.mem.startsWith(u8, name, "Astro.")) self.uses_astro = true;
        if (text.eql(name, "head")) self.explicit_head = true;
        const is_component = text.eql(node_value.type_name, "Component") or std.mem.indexOfScalar(u8, name, '-') != null;
        for (node_value.attributes) |attr| {
            const key = attr.name orelse "";
            if (std.mem.startsWith(u8, key, "transition:")) self.transitions = true;
            if (is_component and text.eql(key, "server:defer")) try self.addComponent(&self.server, name);
            if (std.mem.startsWith(u8, key, "client:")) {
                const directive = key[7..];
                var found = false;
                for (self.directives.items) |item| {
                    if (text.eql(item, directive)) found = true;
                }
                if (!found) try self.directives.append(self.allocator, directive);
                if (!text.eql(directive, "only") and is_component) {
                    var exists = false;
                    for (self.hydrated_names.items) |item| if (text.eql(item, name)) {
                        exists = true;
                    };
                    if (!exists) try self.hydrated_names.append(self.allocator, name);
                }
                if (is_component) try self.addComponent(if (text.eql(directive, "only")) &self.client_only else &self.hydrated, name);
            }
        }
        if (!blocked and hoisted(node_value)) {
            const script: Script = if (styles.attribute(node_value, "src")) |src| .{ .type = "external", .src = src.value orelse "" } else .{ .type = "inline", .code = try self.scriptCode(id) };
            try self.scripts.append(self.allocator, script);
            try self.script_ids.append(self.allocator, id);
        }
        const next_blocked = blocked or text.eql(name, "svg") or text.eql(name, "noscript") or text.eql(name, "template");
        for (node_value.children) |child| try self.scanNode(child, next_blocked, depth + 1);
    }
    fn scriptCode(self: *Emitter, id: u32) ![]const u8 {
        const root = self.session.document.javascript_roots.items[id] orelse return text.trim(self.get(id).value orelse "");
        var tree = self.session.tree;
        tree.root = @fromBackingInt(@intCast(root));
        const script_node = self.get(id);
        var comments: std.ArrayList(yuku.ast.Comment) = .empty;
        for (tree.comments) |comment| {
            if (comment.span.start >= script_node.value_start.? and comment.span.end <= script_node.value_end.?) try comments.append(self.allocator, comment);
        }
        if (comments.items.len > 0) {
            tree.nodes.len = @backingInt(tree.root) + 1;
            tree.flat_comments = comments;
            tree.comment_index = .{};
            tree.token_buffer = .empty;
            tree.tokens = &.{};
            try tree.finalize(tree.root, .{ .attach_comments = true });
        }
        const generated = try yuku.codegen.generate(self.allocator, &tree, .{ .comments = .all, .quotes = .double });
        try self.codegenDiagnostics(generated.diagnostics, false);
        return std.mem.trimEnd(u8, generated.code, " \t\r\n");
    }
    fn originalOffset(self: *Emitter, offset: u32) u32 {
        var low: usize = 0;
        var high = self.mappings.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.mappings.items[mid].generated <= offset) low = mid + 1 else high = mid;
        }
        if (low == 0) return 0;
        const mapping = self.mappings.items[low - 1];
        return mapping.original + @min(mapping.length, offset - mapping.generated);
    }
    fn codegenDiagnostics(self: *Emitter, diagnostics: []const yuku.ast.Diagnostic, generated: bool) !void {
        for (diagnostics) |diagnostic| {
            const start = if (generated) self.originalOffset(diagnostic.span.start) else diagnostic.span.start;
            const end = if (generated) self.originalOffset(diagnostic.span.end) else diagnostic.span.end;
            try self.diagnostics.append(self.allocator, .{
                .region = "transform",
                .severity = if (diagnostic.severity == .info) "information" else diagnostic.severity.toString(),
                .message = try self.allocator.dupe(u8, diagnostic.message),
                .help = if (diagnostic.help) |help| try self.allocator.dupe(u8, help) else null,
                .start = start,
                .end = @max(start, end),
            });
        }
    }
    fn strategy(self: *Emitter) css.Strategy {
        return std.meta.stringToEnum(css.Strategy, self.options.scoped_style_strategy orelse "where") orelse .where;
    }
    fn statement(self: *Emitter, id: Index) !void {
        const span = self.session.tree.span(id);
        try self.anchor(id, null, true);
        try self.js(span.start, span.end);
        try self.put("\n");
    }
    fn generate(self: *Emitter) !Result {
        try self.printMetadata();
        if (self.uses_astro) {
            try self.put("const $$Astro = ");
            try self.helper(.createAstro);
            try self.put("(");
            try self.put(self.options.astro_global_args orelse "\"https://astro.build\"");
            try self.put(");const Astro = $$Astro;\n");
        }
        for (self.exports.items) |id| try self.statement(id);
        const component_name = try componentName(self.allocator, self.options.filename);
        try self.put("const ");
        try self.put(component_name);
        try self.put(" = ");
        try self.helper(.createComponent);
        try self.put("(");
        if (self.has_await) try self.put("async ");
        try self.put("($$result,$$props,$$slots)=>{\n");
        if (self.uses_astro) {
            try self.put("const Astro = $$result.createAstro($$props,$$slots);Astro.self = ");
            try self.put(component_name);
            try self.put(";\n");
        }
        for (self.statements.items) |id| try self.statement(id);
        if (self.vars.items.len > 0) {
            try self.put("const $$definedVars = ");
            try self.helper(.defineStyleVars);
            try self.put("([");
            for (self.vars.items, 0..) |item, i| {
                if (i > 0) try self.put(",");
                try self.attrExpr(item);
            }
            try self.put("]);\n");
        }
        try self.put("return ");
        try self.helper(.render);
        try self.put("`");
        if (self.options.inline_component_assets) for (self.css_text.items) |value| {
            try self.put("<style>");
            try self.template(value);
            try self.put("</style>");
        };
        try self.rootChildren(self.session.document.roots.items);
        if (self.options.inline_component_assets) for (self.script_ids.items, 0..) |_, i| try self.renderScript(i);
        try self.put("`;\n},");
        if (self.options.filename) |filename| try self.string(filename) else try self.put("undefined");
        try self.put(if (self.transitions or self.server.items.len > 0) ",\"self\");\n" else ",undefined);\n");
        try self.put("export default ");
        try self.put(component_name);
        try self.put(";\n");
        const body = self.out;
        const body_mappings = self.mappings;
        self.out = .empty;
        self.mappings = .empty;
        self.helpers.insert(.render);
        self.helpers.insert(.createComponent);
        try self.put("import {");
        var first = true;
        inline for (@import("meta").fields(Helpers)) |field| if (self.helpers.contains(@field(Helpers, field.name))) {
            if (!first) try self.put(",");
            first = false;
            try self.put(field.name);
            if (!text.eql(field.name, "Fragment")) {
                try self.put(" as $$");
                try self.put(field.name);
            }
        };
        try self.put("} from ");
        try self.string(self.options.internal_url orelse "astro/runtime/server/index.js");
        try self.put(";\n");
        if (self.transitions) {
            try self.put("import ");
            try self.string(self.options.transitions_animation_url orelse "transitions.css");
            try self.put(";\n");
        }
        for (self.modules.items) |module| if (!module.skip) try self.statement(module.root);
        if (!self.options.inline_component_assets) for (self.css_text.items, 0..) |_, i| {
            try self.put("import ");
            try self.string(try std.fmt.allocPrint(self.allocator, "{s}?astro&type=style&index={d}&lang.css", .{ self.options.filename orelse "<stdin>", i }));
            try self.put(";\n");
        };
        if (!self.options.resolve_path_provided) for (self.modules.items) |module| if (module.namespace) |i| {
            try self.fmt("import * as $$module{d} from ", .{i});
            try self.string(module.specifier);
            try self.importAttributes(module.root, true);
            try self.put(";\n");
        };
        const base: u32 = @intCast(self.out.items.len);
        for (body_mappings.items) |item| try self.mappings.append(self.allocator, .{ .generated = base + item.generated, .original = item.original, .length = item.length });
        try self.put(body.items);
        const intermediate = try self.out.toOwnedSlice(self.allocator);
        var generated_tree = yuku.ast.Tree.initInArena(self.allocator, intermediate);
        defer generated_tree.deinit();
        generated_tree.lang = .ts;
        // The original AST and emitted ranges give a tighter capacity estimate
        // than treating the generated HTML template as dense JavaScript.
        const estimated_nodes = @max(256, self.session.tree.nodes.len + self.mappings.items.len * 2);
        try generated_tree.nodes.ensureTotalCapacity(self.allocator, estimated_nodes);
        try generated_tree.extras.ensureTotalCapacity(self.allocator, estimated_nodes);
        var generated_parser: yuku.Parser = undefined;
        try generated_parser.initInTree(&generated_tree, .{ .lang = .ts, .source_type = .module }, .{ .start = 0, .end = @intCast(intermediate.len) });
        defer if (generated_parser.initialized) generated_parser.deinit();
        generated_tree = try generated_parser.parse();
        if (generated_tree.hasErrors()) {
            return error.InvalidGeneratedJavaScript;
        }
        try @import("transform_typescript.zig").lower(self.allocator, &generated_tree, self.session.document.frontmatter, self.mappings.items);
        const generated = try yuku.codegen.generate(self.allocator, &generated_tree, .{
            .strip = true,
            .indent = 1,
            .quotes = .double,
            .comments = .all,
            .source_map = if (self.options.sourcemap != null) .{} else null,
        });
        try self.codegenDiagnostics(generated.diagnostics, true);
        var quasis: std.ArrayList(maps.Quasi) = .empty;
        for (generated_tree.nodes.items(.data), generated_tree.nodes.items(.span)) |value, span| if (value == .template_element) {
            try quasis.append(self.allocator, .{ .start = span.start, .end = span.end });
        };
        std.mem.sort(maps.Quasi, quasis.items, {}, struct {
            fn less(_: void, a: maps.Quasi, b: maps.Quasi) bool {
                return a.start < b.start;
            }
        }.less);
        const normalized = try @import("transform_import_attributes.zig").legacy(self.allocator, &generated_tree, generated.code);
        const map = if (generated.map) |value| try maps.compose(self.allocator, value.mappings, intermediate, normalized.code, self.source, self.mappings.items, self.anchors.items, quasis.items, normalized.shifts) else "";
        var failed = false;
        for (self.diagnostics.items) |diagnostic| if (text.eql(diagnostic.severity, "error")) {
            failed = true;
        };
        return .{ .code = if (failed) "" else normalized.code, .map = if (failed) "" else map, .scope = self.hash, .css = self.css_text.items, .scripts = self.scripts.items, .hydrated_components = self.hydrated.items, .client_only_components = self.client_only.items, .server_components = self.server.items, .contains_head = self.explicit_head, .propagation = self.transitions or self.server.items.len > 0, .diagnostics = self.diagnostics.items };
    }
    fn printMetadata(self: *Emitter) Error!void {
        if (self.options.resolve_path_provided) return;
        try self.put("export const $$metadata = ");
        try self.helper(.createMetadata);
        try self.put("(");
        if (self.options.filename) |filename| try self.string(filename) else try self.put("import.meta.url");
        try self.put(",{modules:[");
        var first = true;
        for (self.modules.items) |module| if (module.namespace) |i| {
            if (!first) try self.put(",");
            first = false;
            try self.fmt("{{module:$$module{d},specifier:", .{i});
            try self.string(module.specifier);
            try self.put(",assert:");
            try self.importAttributes(module.root, false);
            try self.put("}");
        };
        try self.put("],hydratedComponents:[");
        var hydrated_first = true;
        for (self.hydrated_names.items) |name| if (std.mem.indexOfScalar(u8, name, '-') != null) {
            if (!hydrated_first) try self.put(",");
            hydrated_first = false;
            try self.string(name);
        };
        var hydrated_index = self.hydrated_names.items.len;
        while (hydrated_index > 0) {
            hydrated_index -= 1;
            const name = self.hydrated_names.items[hydrated_index];
            if (std.mem.indexOfScalar(u8, name, '-') != null) continue;
            if (!hydrated_first) try self.put(",");
            hydrated_first = false;
            try self.put(name);
        }
        try self.put("],clientOnlyComponents:[");
        for (self.client_only.items, 0..) |item, i| {
            if (i > 0) try self.put(",");
            try self.string(item.specifier);
        }
        try self.put("],hydrationDirectives:new Set([");
        for (self.directives.items, 0..) |item, i| {
            if (i > 0) try self.put(",");
            try self.string(item);
        }
        try self.put("]),hoisted:[");
        for (self.scripts.items, 0..) |item, i| {
            if (i > 0) try self.put(",");
            try self.put("{type:");
            try self.string(item.type);
            if (item.code) |value| {
                try self.put(",value:`");
                try self.template(value);
                try self.put("`");
            }
            if (item.src) |value| {
                try self.put(",src:");
                try self.string(value);
            }
            try self.put("}");
        }
        try self.put("]});\n");
    }
    fn maybeHead(self: *Emitter) !void {
        if (self.head_inserted or self.explicit_head or self.in_head) return;
        try self.put("${");
        try self.helper(.maybeRenderHead);
        try self.put("($$result)}");
        self.head_inserted = true;
    }
    fn importAttributes(self: *Emitter, id: Index, declaration: bool) !void {
        const attributes = self.session.tree.extra(self.data(id).import_declaration.attributes);
        if (declaration and attributes.len == 0) return;
        if (declaration) try self.put(" assert ");
        try self.put("{");
        for (attributes, 0..) |item, i| {
            if (i > 0) try self.put(",");
            const attribute = self.data(item).import_attribute;
            if (self.data(attribute.key) == .string_literal) try self.string(self.astName(attribute.key)) else try self.put(self.astName(attribute.key));
            try self.put(":");
            try self.string(self.astName(attribute.value));
        }
        try self.put("}");
    }
    fn needsHeadStart(self: *Emitter, ids: []const u32) bool {
        if (self.explicit_head) return false;
        for (ids) |id| {
            const value = self.get(id);
            if (text.eql(value.type_name, "Text")) {
                if (text.trim(value.value orelse "").len > 0) return false;
            } else if (text.eql(value.type_name, "Expression") or text.eql(value.type_name, "Fragment")) {
                return false;
            } else if (value.name) |name| {
                if (text.eql(name, "script") and self.session.document.javascript_roots.items[id] != null) continue;
                return !text.eql(value.type_name, "Component") and
                    std.mem.indexOfScalar(u8, name, '-') == null and
                    !text.eql(name, "html") and !text.eql(name, "slot") and !isHead(name);
            }
        }
        return false;
    }
    fn renderScript(self: *Emitter, index: usize) !void {
        try self.put("${");
        try self.helper(.renderScript);
        try self.put("($$result,");
        try self.string(try std.fmt.allocPrint(self.allocator, "{s}?astro&type=script&index={d}&lang.ts", .{ self.options.filename orelse "/src/pages/index.astro", index }));
        try self.put(")}");
    }
    fn children(self: *Emitter, ids: []const u32, slot_body: bool) Error!void {
        var remaining: usize = 0;
        var removed_remaining: usize = 0;
        if (self.raw_depth == 0) for (ids) |id| {
            if (!self.invisible(id)) remaining += 1;
            if (self.removedChild(id)) removed_remaining += 1;
        };
        var before = false;
        var removed_before = false;
        for (ids) |id| {
            const value = self.get(id);
            const visible = self.raw_depth == 0 and !self.invisible(id);
            const removed = self.raw_depth == 0 and self.removedChild(id);
            if (visible) remaining -= 1;
            if (removed) removed_remaining -= 1;
            defer {
                before = before or visible;
                removed_before = removed_before or removed;
            }
            if (slot_body and text.eql(value.type_name, "Comment")) continue;
            if (text.eql(value.type_name, "Text") and self.raw_depth == 0 and
                text.trim(value.value orelse "").len == 0 and
                !(slot_body and text.eql(self.options.compact orelse "none", "none")))
            {
                if ((!before and removed_before) or (remaining == 0 and removed_remaining > 0)) continue;
            }
            if (text.eql(value.type_name, "Text") and self.raw_depth == 0 and self.options.compact != null and !text.eql(self.options.compact.?, "none")) {
                const content = value.value orelse value.text;
                if (text.eql(self.options.compact.?, "jsx")) {
                    try self.template(if (slot_body and text.trim(content).len > 0) content else try collapseJsx(self.allocator, content));
                } else try self.template(try collapse(self.allocator, content, ids.len == 1, self.in_head));
            } else try self.node(id, slot_body);
        }
    }
    fn invisible(self: *Emitter, id: u32) bool {
        const value = self.get(id);
        if (text.eql(value.type_name, "Text")) return text.trim(value.value orelse "").len == 0;
        return self.removedChild(id) or text.eql(value.type_name, "Doctype");
    }
    fn removedChild(self: *Emitter, id: u32) bool {
        const value = self.get(id);
        for (self.style_ids) |style| if (style == id) return true;
        if (!text.eql(self.options.compact orelse "none", "none")) {
            for (self.script_ids.items) |script| if (script == id) return true;
            if (text.eql(value.type_name, "Comment")) return true;
        }
        return false;
    }
    fn rootChildren(self: *Emitter, ids: []const u32) Error!void {
        var roots = ids;
        while (roots.len > 0) {
            const value = self.get(roots[0]);
            if (!(text.eql(value.type_name, "Doctype") or (text.eql(value.type_name, "Text") and text.trim(value.value orelse "").len == 0))) break;
            roots = roots[1..];
        }
        while (roots.len > 0) {
            const id = roots[roots.len - 1];
            const value = self.get(id);
            var skip = text.eql(value.type_name, "Doctype") or (text.eql(value.type_name, "Text") and text.trim(value.value orelse "").len == 0);
            for (self.style_ids) |style_id| if (style_id == id) {
                skip = true;
            };
            if (!skip) break;
            roots = roots[0 .. roots.len - 1];
        }
        if (self.needsHeadStart(roots)) try self.maybeHead();
        if (roots.len > 0 and text.eql(self.get(roots[roots.len - 1]).type_name, "Text")) {
            try self.children(roots[0 .. roots.len - 1], false);
            const last = self.get(roots[roots.len - 1]);
            try self.mark(last.start orelse 0);
            try self.template(std.mem.trimEnd(u8, last.value orelse "", " \t\r\n"));
        } else try self.children(roots, false);
    }
    fn hasContent(self: *Emitter, id: u32) bool {
        const value = self.get(id);
        if (text.eql(value.type_name, "Text")) return text.trim(value.value orelse "").len > 0;
        if (text.eql(value.type_name, "Expression")) {
            if (value.children.len > 0 and self.session.document.javascript_roots.items[id] == null) return true;
            const root = self.session.document.javascript_roots.items[id] orelse return false;
            return root != std.math.maxInt(u32);
        }
        return !text.eql(value.type_name, "Doctype") and !text.eql(value.type_name, "Comment");
    }
    fn childHasAwait(self: *Emitter, ids: []const u32) bool {
        if (!self.has_await) return false;
        for (ids) |id| {
            const value = self.get(id);
            for (self.session.tree.nodes.items(.data), self.session.tree.nodes.items(.span)) |data_value, span| {
                if (span.start < (value.start orelse 0) or span.end > (value.end orelse 0)) continue;
                if (data_value == .await_expression or (data_value == .for_of_statement and data_value.for_of_statement.await) or
                    (data_value == .variable_declaration and data_value.variable_declaration.kind == .await_using)) return true;
            }
        }
        return false;
    }
    fn node(self: *Emitter, id: u32, slot_body: bool) Error!void {
        if (self.nesting >= 256) return error.CodegenNestingTooDeep;
        self.nesting += 1;
        defer self.nesting -= 1;
        const value = self.get(id);
        if (text.eql(value.type_name, "Text")) {
            try self.mark(value.start orelse 0);
            try self.template(value.value orelse value.text);
            return;
        }
        if (text.eql(value.type_name, "Comment")) {
            if (!slot_body) {
                try self.put("<!--");
                try self.template(value.value orelse "");
                try self.put("-->");
            }
            return;
        }
        if (text.eql(value.type_name, "Doctype")) {
            return;
        }
        if (text.eql(value.type_name, "Expression")) {
            const start = value.value_start orelse return;
            const end = value.value_end orelse return;
            if (text.trim(self.source[start..end]).len == 0) {
                try self.put("${(void 0)}");
                return;
            }
            if (self.session.document.javascript_roots.items[id] == std.math.maxInt(u32)) return;
            if (self.session.document.javascript_roots.items[id] == null and value.children.len > 0) {
                try self.put("${");
                try self.helper(.render);
                try self.put("`");
                try self.children(value.children, slot_body);
                try self.put("`}");
                return;
            }
            const root: Index = @fromBackingInt(@intCast(self.session.document.javascript_roots.items[id] orelse std.math.maxInt(u32)));
            if (root != .null) try self.expressionAnchors(root, if (self.data(root) == .identifier_reference) value.start else null, 0);
            try self.mark(value.start orelse start);
            try self.put("${");
            try self.js(start, end);
            try self.put("}");
            return;
        }
        const name = value.name orelse "";
        if (text.eql(value.type_name, "Fragment") or text.eql(name, "Fragment")) {
            if (value.implicit_fragment) try self.children(value.children, slot_body) else {
                var fragment = value.*;
                fragment.name = "Fragment";
                self.helpers.insert(.Fragment);
                try self.component(&fragment);
            }
            return;
        }
        for (self.style_ids) |style_id| if (style_id == id) return;
        for (self.script_ids.items, 0..) |script_id, i| if (script_id == id) {
            if (!self.options.inline_component_assets) try self.renderScript(i);
            return;
        };
        if (text.eql(name, "slot") and styles.attribute(value, "is:inline") == null) {
            try self.mark(value.start orelse 0);
            try self.put("${");
            try self.helper(.renderSlot);
            try self.put("($$result,$$slots[");
            if (styles.attribute(value, "name")) |attr| {
                const dynamic = text.eql(attr.kind, "expression") or text.eql(attr.kind, "shorthand");
                if (dynamic) try self.put("\"\"+");
                try self.attrExpr(attr);
                if (dynamic) try self.put("+\"\"");
            } else try self.string("default");
            try self.put("]");
            if (value.children.len > 0) {
                try self.put(",");
                try self.helper(.render);
                try self.put("`");
                try self.children(value.children, false);
                try self.put("`");
            }
            try self.put(")}");
            return;
        }
        if (text.eql(value.type_name, "Component") or std.mem.indexOfScalar(u8, name, '-') != null) {
            try self.component(value);
            return;
        }
        const raw = value.raw or text.eql(name, "pre") or text.eql(name, "textarea") or text.eql(name, "script") or text.eql(name, "style");
        if (raw) self.raw_depth += 1;
        defer if (raw) {
            self.raw_depth -= 1;
        };
        const saved_head = self.in_head;
        if (text.eql(name, "head")) self.in_head = true;
        defer self.in_head = saved_head;
        if (!isHead(name)) try self.maybeHead();
        try self.mark(value.start orelse 0);
        try self.put("<");
        try self.put(name);
        try self.htmlAttributes(value);
        try self.put(">");
        if (text.eql(name, "template")) {
            try self.put("${");
            try self.helper(.templateEnter);
            try self.put("($$result)}");
        }
        if (styles.attribute(value, "set:html") != null or styles.attribute(value, "set:text") != null) {
            try self.setDirective(value);
        } else if (text.eql(name, "script")) {
            if (styles.attribute(value, "define:vars")) |vars| {
                const module = if (styles.attribute(value, "type")) |attr| text.eql(attr.value orelse "", "module") else false;
                if (!module) try self.put("(function(){");
                try self.put("${");
                try self.helper(.defineScriptVars);
                try self.put("(");
                try self.attrExpr(vars);
                try self.put(")}");
                try self.template(self.source[value.value_start.?..value.value_end.?]);
                if (!module) try self.put("})();");
            } else {
                try self.mark(value.value_start.?);
                try self.template(self.source[value.value_start.?..value.value_end.?]);
            }
        } else if (text.eql(name, "style")) try self.template(self.source[value.value_start.?..value.value_end.?]) else try self.children(value.children, false);
        if (text.eql(name, "head")) {
            try self.put("${");
            try self.helper(.renderHead);
            try self.put("($$result)}");
            self.head_inserted = true;
        }
        if (text.eql(name, "template")) {
            try self.put("${");
            try self.helper(.templateExit);
            try self.put("($$result)}");
        }
        if (!voidElement(name)) {
            try self.mark(value.closing_start orelse value.end orelse 0);
            try self.put(if (text.eql(name, "script") or text.eql(name, "style")) "<\\/" else "</");
            try self.put(name);
            try self.put(">");
        }
    }
    fn setDirective(self: *Emitter, value: *const Node) Error!void {
        const html = styles.attribute(value, "set:html");
        const item = html orelse styles.attribute(value, "set:text").?;
        if (html == null and (text.eql(item.kind, "quoted") or text.eql(item.kind, "unquoted"))) try self.template(try self.decoded(item.value orelse "")) else {
            try self.put("${");
            if (html != null) {
                try self.helper(.unescapeHTML);
                try self.put("(");
            }
            try self.attrExpr(item);
            if (html != null) try self.put(")");
            try self.put("}");
        }
    }
    fn htmlAttr(self: *Emitter, item: Attr, key: []const u8) Error!void {
        try self.mark(item.start);
        if (text.eql(item.kind, "boolean")) {
            try self.put(" ");
            try self.template(key);
        } else if ((text.eql(item.kind, "quoted") or text.eql(item.kind, "unquoted"))) {
            try self.put(" ");
            try self.template(key);
            try self.put("=\"");
            try self.htmlString(item.value orelse "");
            try self.put("\"");
        } else {
            try self.put("${");
            try self.helper(.addAttribute);
            try self.put("(");
            try self.attrExpr(item);
            try self.put(",");
            try self.string(key);
            try self.put(")}");
        }
    }
    fn htmlString(self: *Emitter, source: []const u8) !void {
        var start: usize = 0;
        for (source, 0..) |c, i| {
            const replacement: ?[]const u8 = switch (c) {
                '"' => "&quot;",
                '<' => "&lt;",
                '>' => "&gt;",
                '&' => if (entityPrefix(source[i..])) null else "&amp;",
                else => null,
            };
            if (replacement) |value| {
                try self.template(source[start..i]);
                try self.put(value);
                start = i + 1;
            }
        }
        try self.template(source[start..]);
    }
    fn htmlAttributes(self: *Emitter, value: *const Node) Error!void {
        const scoped = self.scoped and css.shouldScope(value.name orelse "");
        var scope_injected = false;
        const vars = self.vars.items.len > 0 and shouldVars(value.name orelse "");
        var vars_injected = false;
        if (styles.attribute(value, "transition:persist")) |persist| {
            const persist_value: []const u8 = persist.value orelse "x";
            if (!text.eql(persist.kind, "boolean") and persist_value.len > 0) {
                try self.htmlAttr(persist, "data-astro-transition-persist");
            } else if (styles.attribute(value, "transition:name")) |name| {
                try self.htmlAttr(name, "data-astro-transition-persist");
            } else {
                try self.put("${");
                try self.helper(.addAttribute);
                try self.put("(");
                try self.helper(.createTransitionScope);
                try self.put("($$result,");
                try self.string(try self.transitionHash());
                try self.put("),\"data-astro-transition-persist\")}");
            }
        }
        for (value.attributes) |item| {
            if (text.eql(item.kind, "comment")) continue;
            var key = self.attributeName(item);
            if (text.eql(key, "transition:persist-props")) {
                try self.htmlAttr(item, "data-astro-transition-persist-props");
                continue;
            }
            if (text.eql(item.kind, "spread")) {
                try self.put("${");
                try self.helper(.spreadAttributes);
                try self.put("(");
                try self.attrExpr(item);
                if (scoped and !scope_injected and styles.attribute(value, "class") == null and styles.attribute(value, "class:list") == null) {
                    try self.put(",undefined,{\"class\":");
                    try self.string(try std.fmt.allocPrint(self.allocator, "astro-{s}", .{self.hash}));
                    try self.put("}");
                    scope_injected = self.strategy() != .attribute;
                }
                try self.put(")}");
                continue;
            }
            if (text.eql(key, "slot") and self.skip_slot) continue;
            if (std.mem.startsWith(u8, key, "set:") or std.mem.startsWith(u8, key, "is:") or std.mem.startsWith(u8, key, "define:") or std.mem.startsWith(u8, key, "transition:")) continue;
            if (text.eql(key, "class") and styles.attribute(value, "class:list") != null) continue;
            if (text.eql(key, "style") and vars) {
                try self.put("${");
                try self.helper(.addAttribute);
                const root = if (item.expression) |expression| self.session.document.javascript_roots.items[expression] else null;
                if (text.eql(item.kind, "boolean")) {
                    try self.put("($$definedVars");
                } else if (root != null and self.data(@fromBackingInt(@intCast(root.?))) == .object_expression) {
                    try self.put("([");
                    try self.attrExpr(item);
                    try self.put(",$$definedVars]");
                } else {
                    try self.put("(`${");
                    try self.attrExpr(item);
                    try self.put("}; ${$$definedVars}`");
                }
                try self.put(",\"style\")}");
                vars_injected = true;
                self.defined_vars_injected = true;
                continue;
            }
            if (text.eql(key, "class") and scoped and self.strategy() != .attribute) {
                if ((text.eql(item.kind, "quoted") or text.eql(item.kind, "unquoted")) or text.eql(item.kind, "boolean")) {
                    try self.put(" class=\"");
                    try self.template(item.value orelse "");
                    if (item.value) |v| if (v.len > 0) {
                        try self.put(" ");
                    };
                    try self.put("astro-");
                    try self.put(self.hash);
                    try self.put("\"");
                } else {
                    try self.put("${");
                    try self.helper(.addAttribute);
                    try self.put("(((");
                    try self.attrExpr(item);
                    try self.put(")??\"\")+\" astro-");
                    try self.put(self.hash);
                    try self.put("\",\"class\")}");
                }
                scope_injected = true;
                continue;
            }
            if (text.eql(key, "class:list")) {
                const static = styles.attribute(value, "class");
                if ((text.eql(item.kind, "quoted") or text.eql(item.kind, "unquoted") or text.eql(item.kind, "boolean")) and static == null and !scoped) {
                    var spread = false;
                    for (value.attributes) |attr| if (text.eql(attr.kind, "spread")) {
                        spread = true;
                    };
                    try self.htmlAttr(item, if (spread) "class:list" else "class");
                    continue;
                }
                try self.put("${");
                try self.helper(.addAttribute);
                const grouped = static != null or (scoped and self.strategy() != .attribute);
                try self.put("(");
                if (grouped) try self.put("[");
                if (static) |class_attr| {
                    try self.attrExpr(class_attr);
                    try self.put(",");
                }
                try self.attrExpr(item);
                if (scoped and self.strategy() != .attribute) {
                    try self.put(",");
                    try self.string(try std.fmt.allocPrint(self.allocator, "astro-{s}", .{self.hash}));
                    scope_injected = true;
                }
                if (grouped) try self.put("]");
                try self.put(",\"class:list\")}");
                continue;
            }
            if (text.eql(item.kind, "shorthand") and key.len == 0) key = item.value orelse "";
            try self.htmlAttr(item, key);
        }
        if (vars and !vars_injected) {
            try self.put("${");
            try self.helper(.addAttribute);
            try self.put("($$definedVars,\"style\")}");
            self.defined_vars_injected = true;
        }
        if (scoped and !scope_injected) {
            if (self.strategy() == .attribute) {
                try self.put(" data-astro-cid-");
                try self.put(self.hash);
            } else {
                try self.put(" class=\"astro-");
                try self.put(self.hash);
                try self.put("\"");
            }
        }
        try self.transitionAttributes(value, false);
        if (self.options.annotate_source_file and !text.eql(value.name orelse "", "html") and !text.eql(value.name orelse "", "head") and !text.eql(value.name orelse "", "script") and !text.eql(value.name orelse "", "style")) {
            try self.put(" data-astro-source-file=\"");
            try self.template(self.options.filename orelse "<stdin>");
            try self.put("\" data-astro-source-loc=\"");
            const offset = if (value.children.len > 0) self.get(value.children[0]).start orelse 0 else value.name_start orelse 0;
            const lc = maps.lineCol(self.source, offset);
            try self.fmt("{d}:{d}", .{ lc.line + 1, lc.column + 1 });
            try self.put("\"");
        }
    }
    fn component(self: *Emitter, value: *const Node) Error!void {
        try self.mark(value.start orelse 0);
        const name = value.name.?;
        const custom = std.mem.indexOfScalar(u8, name, '-') != null;
        const only = styles.attribute(value, "client:only") != null;
        try self.put("${");
        try self.helper(.renderComponent);
        try self.put("($$result,");
        try self.string(name);
        try self.put(",");
        if (only) try self.put("null") else if (custom) try self.string(name) else try self.put(name);
        try self.put(",{");
        var first = true;
        var class_injected = false;
        var vars_injected = false;
        const scoped = self.scoped and css.shouldScope(name);
        for (value.attributes) |item| {
            if (text.eql(item.kind, "comment")) continue;
            const key = self.attributeName(item);
            if (std.mem.startsWith(u8, key, "set:") or std.mem.startsWith(u8, key, "is:") or std.mem.startsWith(u8, key, "transition:") or text.eql(key, "server:defer")) continue;
            if (!first) try self.put(",");
            first = false;
            if (text.eql(item.kind, "spread")) {
                try self.put("...(");
                try self.attrExpr(item);
                try self.put(")");
            } else {
                try self.string(key);
                try self.put(":");
                if (custom and self.vars.items.len > 0 and text.eql(key, "style")) {
                    vars_injected = true;
                    const root = if (item.expression) |id| self.session.document.javascript_roots.items[id] else null;
                    if (text.eql(item.kind, "boolean")) try self.put("$$definedVars") else if (root != null and self.data(@fromBackingInt(@intCast(root.?))) == .object_expression) {
                        try self.put("[");
                        try self.attrExpr(item);
                        try self.put(",$$definedVars]");
                    } else {
                        try self.put("`${");
                        try self.propExpr(item);
                        try self.put("}; ${$$definedVars}`");
                    }
                } else if (scoped and (text.eql(key, "class") or (!custom and text.eql(key, "className"))) and self.strategy() != .attribute) {
                    if (text.eql(item.kind, "quoted") or text.eql(item.kind, "unquoted") or text.eql(item.kind, "boolean")) {
                        const value_text = item.value orelse "";
                        try self.propString(try std.fmt.allocPrint(self.allocator, "{s}{s}astro-{s}", .{ value_text, if (value_text.len > 0) " " else "", self.hash }));
                    } else {
                        try self.put("(((");
                        try self.attrExpr(item);
                        try self.put(")??\"\")+\" astro-");
                        try self.put(self.hash);
                        try self.put("\")");
                    }
                    class_injected = true;
                } else try self.propExpr(item);
            }
        }
        if (scoped and !class_injected) {
            if (!first) try self.put(",");
            first = false;
            if (self.strategy() == .attribute) {
                try self.string(try std.fmt.allocPrint(self.allocator, "data-astro-cid-{s}", .{self.hash}));
                try self.put(":true");
            } else {
                try self.put("\"class\":");
                try self.string(try std.fmt.allocPrint(self.allocator, "astro-{s}", .{self.hash}));
            }
        }
        if (custom and self.vars.items.len > 0 and !vars_injected) {
            if (!first) try self.put(",");
            first = false;
            try self.put("\"style\":$$definedVars");
        }
        if (custom and self.options.annotate_source_file) {
            if (!first) try self.put(",");
            first = false;
            try self.put("\"data-astro-source-file\":");
            try self.string(self.options.filename orelse "<stdin>");
            try self.put(",\"data-astro-source-loc\":");
            const lc = maps.lineCol(self.source, value.name_start orelse 0);
            try self.string(try std.fmt.allocPrint(self.allocator, "{d}:{d}", .{ lc.line + 1, lc.column + 1 }));
        }
        for (value.attributes) |item| {
            const key = item.name orelse "";
            if (std.mem.startsWith(u8, key, "client:")) {
                if (!first) try self.put(",");
                first = false;
                try self.put("\"client:component-hydration\":");
                try self.string(key[7..]);
                if (try self.metadata(name)) |meta| {
                    try self.put(",\"client:component-path\":");
                    if (only and !self.options.resolve_path_provided) try self.put("$$metadata.resolvePath(");
                    try self.string(if (self.options.resolve_path_provided) meta.resolved_path else meta.specifier);
                    if (only and !self.options.resolve_path_provided) try self.put(")");
                    try self.put(",\"client:component-export\":");
                    try self.string(meta.export_name);
                }
                break;
            }
        }
        if (styles.attribute(value, "server:defer") != null) {
            if (!first) try self.put(",");
            first = false;
            try self.put("\"server:component-directive\":\"defer\"");
            if (try self.metadata(name)) |meta| {
                try self.put(",\"server:component-path\":");
                try self.string(meta.resolved_path);
                try self.put(",\"server:component-export\":");
                try self.string(meta.export_name);
            }
        }
        if (styles.attribute(value, "transition:name") != null or styles.attribute(value, "transition:animate") != null or styles.attribute(value, "transition:persist") != null or styles.attribute(value, "transition:persist-props") != null) {
            if (!first) try self.put(",");
            try self.transitionAttributes(value, true);
        }
        try self.put("}");
        if (styles.attribute(value, "set:html") != null or styles.attribute(value, "set:text") != null) {
            try self.put(",{default:");
            if (self.has_await) try self.put("async ");
            try self.put(if (self.options.result_scoped_slot) "($$result)=>" else "()=>");
            try self.helper(.render);
            try self.put("`");
            try self.setDirective(value);
            try self.put("`}");
        } else if (text.eql(name, "Fragment") and self.source[(value.start orelse 0) + 1] == '>') {
            try self.put(",{default:");
            if (self.childHasAwait(value.children)) try self.put("async ");
            try self.put(if (self.options.result_scoped_slot) "($$result)=>" else "()=>");
            try self.helper(.render);
            try self.put("`");
            const saved = self.skip_slot;
            self.skip_slot = false;
            try self.children(value.children, false);
            self.skip_slot = saved;
            try self.put("`}");
        } else if (value.children.len > 0) {
            try self.put(",");
            try self.slots(value.children, custom);
        }
        try self.put(")}");
    }
    fn slots(self: *Emitter, children_ids: []const u32, custom: bool) Error!void {
        const Group = struct { key: ?Attr, children: std.ArrayList(u32) = .empty };
        var groups: std.ArrayList(Group) = .empty;
        var conditional: std.ArrayList(u32) = .empty;
        var mapped: std.ArrayList(u32) = .empty;
        try groups.append(self.allocator, .{ .key = null });
        for (children_ids, 0..) |id, child_index| {
            const value = self.get(id);
            if (text.eql(value.type_name, "Comment")) continue;
            if (text.eql(value.type_name, "Expression") and !self.hasContent(id)) continue;
            if (!custom and text.eql(value.type_name, "Text") and text.trim(value.value orelse "").len == 0) {
                const previous_expression = child_index > 0 and text.eql(self.get(children_ids[child_index - 1]).type_name, "Expression");
                const next_expression = child_index + 1 < children_ids.len and text.eql(self.get(children_ids[child_index + 1]).type_name, "Expression");
                if (previous_expression or (child_index == 0 and next_expression)) continue;
            }
            var key: ?Attr = if (custom) null else styles.attribute(value, "slot");
            if (!custom and key == null and text.eql(value.type_name, "Expression")) {
                if (self.session.document.javascript_roots.items[id]) |root| {
                    var keys: std.ArrayList(Attr) = .empty;
                    try self.collectSlotKeys(@fromBackingInt(@intCast(root)), &keys, 0);
                    if (keys.items.len > 0) {
                        if (self.mappedSlot(@fromBackingInt(@intCast(root)), keys.items)) {
                            try mapped.append(self.allocator, id);
                            continue;
                        }
                        if (keys.items.len > 1) {
                            try conditional.append(self.allocator, id);
                            continue;
                        }
                        key = keys.items[0];
                    }
                }
            }
            var group: ?usize = null;
            for (groups.items, 0..) |item, i| if ((item.key == null and key == null) or (item.key != null and key != null and text.eql(item.key.?.value orelse "", key.?.value orelse ""))) {
                group = i;
                break;
            };
            if (group == null) {
                group = groups.items.len;
                try groups.append(self.allocator, .{ .key = key });
            }
            try groups.items[group.?].children.append(self.allocator, id);
        }
        std.mem.sort(Group, groups.items, {}, struct {
            fn rank(group: Group) u8 {
                if (group.key == null) return 0;
                return if (text.eql(group.key.?.kind, "quoted") or text.eql(group.key.?.kind, "unquoted")) 1 else 2;
            }
            fn less(_: void, a: Group, b: Group) bool {
                return rank(a) < rank(b);
            }
        }.less);
        const merge = conditional.items.len > 0 or mapped.items.len > 0;
        if (merge) {
            try self.helper(.mergeSlots);
            try self.put("(");
        }
        try self.put("{");
        const saved_skip = self.skip_slot;
        defer self.skip_slot = saved_skip;
        var first_group = true;
        for (groups.items) |group| {
            var content = false;
            for (group.children.items) |id| if (self.hasContent(id)) {
                content = true;
                break;
            };
            if (!content) continue;
            if (!first_group) try self.put(",");
            first_group = false;
            if (group.key) |attr| {
                const dynamic = !text.eql(attr.kind, "quoted") and !text.eql(attr.kind, "unquoted");
                if (dynamic) try self.put("[");
                try self.attrExpr(attr);
                if (dynamic) try self.put("]");
            } else try self.string("default");
            try self.put(":");
            if (self.childHasAwait(group.children.items)) try self.put("async ");
            try self.put(if (self.options.result_scoped_slot) "($$result)=>" else "()=>");
            try self.helper(.render);
            try self.put("`");
            self.skip_slot = !custom and group.key != null;
            try self.children(group.children.items, true);
            try self.put("`");
        }
        try self.put("}");
        for (conditional.items) |id| {
            try self.put(",");
            try self.slotJs(@fromBackingInt(@intCast(self.session.document.javascript_roots.items[id].?)), false, false, 0);
        }
        for (mapped.items) |id| {
            try self.put(",");
            const root: Index = @fromBackingInt(@intCast(self.session.document.javascript_roots.items[id].?));
            if (self.has_await and self.expressionAsync(root)) {
                try self.put("await (async function $$collectSlots($$v){$$v=await $$v;return Array.isArray($$v)?Object.assign({},...await Promise.all($$v.map($$collectSlots))):$$v&&typeof $$v===\"object\"?$$v:{};})(");
            } else {
                try self.put("(function $$collectSlots($$v){return Array.isArray($$v)?$$v.reduce((a,x)=>Object.assign(a,$$collectSlots(x)),{}):$$v&&typeof $$v===\"object\"?$$v:{};})(");
            }
            try self.slotJs(root, true, false, 0);
            try self.put(")");
        }
        if (merge) try self.put(")");
    }
    fn markup(self: *Emitter, id: Index) ?u32 {
        if (id == .null or self.data(id) != .dialect) return null;
        return self.session.document.embedded.get(id);
    }

    fn collectSlotKeys(self: *Emitter, id: Index, keys: *std.ArrayList(Attr), depth: u32) Error!void {
        if (id == .null) return;
        if (depth >= 256) return error.CodegenNestingTooDeep;
        if (self.markup(id)) |native_id| {
            if (styles.attribute(self.get(native_id), "slot")) |attr| try keys.append(self.allocator, attr);
            return;
        }
        switch (self.data(id)) {
            .conditional_expression => |v| {
                try self.collectSlotKeys(v.consequent, keys, depth + 1);
                try self.collectSlotKeys(v.alternate, keys, depth + 1);
            },
            .logical_expression => |v| try self.collectSlotKeys(v.right, keys, depth + 1),
            inline .parenthesized_expression, .chain_expression, .ts_as_expression, .ts_satisfies_expression, .ts_non_null_expression => |v| try self.collectSlotKeys(v.expression, keys, depth + 1),
            inline .await_expression, .spread_element => |v| try self.collectSlotKeys(v.argument, keys, depth + 1),
            .member_expression => |v| try self.collectSlotKeys(v.object, keys, depth + 1),
            .call_expression => |v| {
                try self.collectSlotKeys(v.callee, keys, depth + 1);
                for (self.session.tree.extra(v.arguments)) |arg| try self.collectSlotKeys(arg, keys, depth + 1);
            },
            .array_expression => |v| for (self.session.tree.extra(v.elements)) |child| {
                try self.collectSlotKeys(child, keys, depth + 1);
            },
            inline .function, .arrow_function_expression => |v| {
                if (self.data(v.body) == .function_body) {
                    const span = self.session.tree.span(v.body);
                    for (self.session.tree.nodes.items(.data), self.session.tree.nodes.items(.span)) |item, location| {
                        if (item == .return_statement and location.start >= span.start and location.end <= span.end)
                            try self.collectSlotKeys(item.return_statement.argument, keys, depth + 1);
                    }
                } else try self.collectSlotKeys(v.body, keys, depth + 1);
            },
            else => {},
        }
    }
    fn mappedSlot(self: *Emitter, initial: Index, keys: []const Attr) bool {
        var id = initial;
        while (self.data(id) == .parenthesized_expression) id = self.data(id).parenthesized_expression.expression;
        if (self.data(id) == .array_expression) return true;
        const span = self.session.tree.span(initial);
        for (keys) |key| {
            if (text.eql(key.kind, "quoted") or text.eql(key.kind, "unquoted")) continue;
            for (self.session.tree.nodes.items(.data), self.session.tree.nodes.items(.span)) |reference, reference_span| {
                if (reference != .identifier_reference or reference_span.start < key.value_start.? or reference_span.end > key.value_end.?) continue;
                const name = self.session.tree.string(reference.identifier_reference.name);
                for (self.session.tree.nodes.items(.data), self.session.tree.nodes.items(.span)) |binding, binding_span| {
                    if (binding == .binding_identifier and binding_span.start >= span.start and binding_span.end <= span.end and
                        text.eql(self.session.tree.string(binding.binding_identifier.name), name)) return true;
                }
            }
        }
        return false;
    }
    fn expressionAsync(self: *Emitter, id: Index) bool {
        const span = self.session.tree.span(id);
        for (self.session.tree.nodes.items(.data), self.session.tree.nodes.items(.span)) |value, location| {
            if (location.start < span.start or location.end > span.end) continue;
            if ((value == .arrow_function_expression and value.arrow_function_expression.async) or
                (value == .function and value.function.async)) return true;
        }
        return false;
    }
    fn slotJs(self: *Emitter, id: Index, mapped: bool, wrap_markup: bool, depth: u32) Error!void {
        if (id == .null) return;
        if (depth >= 256) return error.CodegenNestingTooDeep;
        const span = self.session.tree.span(id);
        if (self.markup(id)) |native_id| {
            if (!wrap_markup) return self.js(span.start, span.end);
            const value = self.get(native_id);
            const key = styles.attribute(value, "slot");
            try self.put("{");
            if (key) |attr| {
                const dynamic = !text.eql(attr.kind, "quoted") and !text.eql(attr.kind, "unquoted");
                if (dynamic) try self.put("[");
                try self.attrExpr(attr);
                if (dynamic) try self.put("]");
            } else try self.string("default");
            try self.put(":");
            if (self.childHasAwait(&.{native_id})) try self.put("async ");
            try self.put(if (self.options.result_scoped_slot) "($$result)=>" else "()=>");
            try self.helper(.render);
            try self.put("`");
            const saved = self.skip_slot;
            self.skip_slot = key != null;
            try self.node(native_id, true);
            self.skip_slot = saved;
            try self.put("`}");
            return;
        }
        switch (self.data(id)) {
            .parenthesized_expression => |v| {
                try self.put("(");
                try self.slotJs(v.expression, mapped, wrap_markup, depth + 1);
                try self.put(")");
            },
            .conditional_expression => |v| {
                try self.slotJsPart(v.@"test", false, false, depth);
                try self.put("?");
                try self.slotJsPart(v.consequent, mapped, true, depth);
                try self.put(":");
                try self.slotJsPart(v.alternate, mapped, true, depth);
            },
            .logical_expression => |v| {
                const left = self.session.tree.span(v.left);
                const right = self.session.tree.span(v.right);
                try self.js(left.start, right.start);
                try self.slotJsPart(v.right, mapped, true, depth);
            },
            .call_expression => |v| {
                try self.slotJs(v.callee, mapped, false, depth + 1);
                if (v.optional) try self.put("?.");
                try self.put("(");
                for (self.session.tree.extra(v.arguments), 0..) |arg, i| {
                    if (i > 0) try self.put(",");
                    try self.slotJs(arg, mapped, false, depth + 1);
                }
                try self.put(")");
            },
            .member_expression => |v| {
                try self.slotJsPart(v.object, mapped, false, depth);
                const object = self.session.tree.span(v.object);
                try self.js(object.end, span.end);
            },
            .chain_expression => |v| try self.slotJs(v.expression, mapped, wrap_markup, depth + 1),
            .array_expression => |v| {
                try self.put("[");
                for (self.session.tree.extra(v.elements), 0..) |child, i| {
                    if (i > 0) try self.put(",");
                    try self.slotJs(child, mapped, true, depth + 1);
                }
                try self.put("]");
            },
            .spread_element => |v| {
                try self.put("...");
                try self.slotJs(v.argument, mapped, true, depth + 1);
            },
            inline .function, .arrow_function_expression => |v| {
                const body = self.session.tree.span(v.body);
                var start = span.start;
                if (mapped and !self.has_await and v.async and std.mem.startsWith(u8, self.source[start..], "async")) start += 5;
                try self.copy(start, body.start);
                if (self.data(v.body) == .function_body) {
                    try self.slotBody(body.start, body.end, mapped, depth + 1);
                } else {
                    try self.slotJsPart(v.body, mapped, true, depth);
                }
            },
            else => try self.js(span.start, span.end),
        }
    }
    fn slotJsPart(self: *Emitter, id: Index, mapped: bool, wrap_markup: bool, depth: u32) Error!void {
        try self.put("(");
        try self.slotJs(id, mapped, wrap_markup, depth + 1);
        try self.put(")");
    }
    fn slotBody(self: *Emitter, start: u32, end: u32, mapped: bool, depth: u32) Error!void {
        var pos = start;
        while (pos < end) {
            var next: Index = .null;
            var next_start = end;
            for (self.session.tree.nodes.items(.data), self.session.tree.nodes.items(.span)) |value, span| {
                if (value != .return_statement or value.return_statement.argument == .null) continue;
                const argument = self.session.tree.span(value.return_statement.argument);
                if (span.start >= pos and span.end <= end and argument.start < next_start) {
                    next = value.return_statement.argument;
                    next_start = argument.start;
                }
            }
            try self.js(pos, next_start);
            if (next == .null) break;
            try self.slotJs(next, mapped, true, depth + 1);
            pos = self.session.tree.span(next).end;
        }
    }
    fn transitionHash(self: *Emitter) ![]const u8 {
        const input = try std.fmt.allocPrint(self.allocator, "{s}-{d}", .{ self.hash, self.transition_counter });
        self.transition_counter += 1;
        return scopeHash(self.allocator, input, input);
    }
    fn transitionAttributes(self: *Emitter, value: *const Node, component_attrs: bool) Error!void {
        const name = styles.attribute(value, "transition:name");
        const animate = styles.attribute(value, "transition:animate");
        const persist = styles.attribute(value, "transition:persist");
        const props = styles.attribute(value, "transition:persist-props");
        var first = true;
        if (name != null or animate != null) {
            if (component_attrs) try self.put("\"data-astro-transition-scope\":") else {
                try self.put("${");
                try self.helper(.addAttribute);
                try self.put("(");
            }
            try self.helper(.renderTransition);
            try self.put("($$result,");
            try self.string(try self.transitionHash());
            try self.put(",");
            if (animate) |attr| try self.attrExpr(attr) else try self.string("");
            try self.put(",");
            if (name) |attr| try self.attrExpr(attr) else try self.string("");
            try self.put(")");
            if (!component_attrs) try self.put(",\"data-astro-transition-scope\")}");
            first = false;
        }
        if (props) |attr| {
            if (component_attrs) {
                if (!first) try self.put(",");
                first = false;
                try self.put("\"data-astro-transition-persist-props\":");
                try self.attrExpr(attr);
            }
        }
        if (component_attrs) if (persist) |attr| {
            if (component_attrs) {
                if (!first) try self.put(",");
                try self.put("\"data-astro-transition-persist\":");
            } else {
                try self.put("${");
                try self.helper(.addAttribute);
                try self.put("(");
            }
            if (!text.eql(attr.kind, "boolean")) try self.attrExpr(attr) else if (name) |n| try self.attrExpr(n) else {
                try self.helper(.createTransitionScope);
                try self.put("($$result,");
                try self.string(try self.transitionHash());
                try self.put(")");
            }
            if (!component_attrs) try self.put(",\"data-astro-transition-persist\")}");
            first = false;
        };
    }
};

fn hoisted(node: *const Node) bool {
    if (!text.eql(node.name orelse "", "script")) return false;
    var src = false;
    var module = false;
    for (node.attributes) |attr| {
        const key = attr.name orelse return false;
        if (text.eql(key, "src")) src = true else if (text.eql(key, "type") and text.eql(attr.value orelse "", "module")) module = true else return false;
    }
    return if (src) !module else true;
}
fn cssSpecifier(value: []const u8) bool {
    const extension = value[(std.mem.lastIndexOfScalar(u8, value, '.') orelse return false) + 1 ..];
    for ([_][]const u8{ "css", "pcss", "postcss", "sass", "scss", "styl", "stylus", "less" }) |ext| if (text.eql(ext, extension)) return true;
    return false;
}
fn isHead(name: []const u8) bool {
    for ([_][]const u8{ "html", "head", "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title" }) |value| if (text.eql(name, value)) return true;
    return false;
}
fn voidElement(name: []const u8) bool {
    for ([_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "selectedcontent", "source", "track", "wbr" }) |value| if (text.eql(name, value)) return true;
    return false;
}
fn shouldVars(name: []const u8) bool {
    return !isHead(name) and !text.eql(name, "body") and !text.eql(name, "slot");
}
fn entityPrefix(source: []const u8) bool {
    return source.len > 1 and source[0] == '&' and (std.ascii.isAlphabetic(source[1]) or source[1] == '#');
}
// Adapted from Astro's escape_len and unicode_escape_len, whose escape table
// is adapted from OXC's lexer (crates/oxc_parser/src/lexer/unicode.rs).
// Copyright (c) 2024-present VoidZero Inc. & Contributors
// Copyright (c) 2023 Boshen
fn jsEscapeLength(source: []const u8) usize {
    if (source.len == 0) return 0;
    const c = source[0];
    if (std.mem.indexOfScalar(u8, "nrtbfv\\'\"`\n", c) != null) return 1;
    if (c == '\r') return if (source.len > 1 and source[1] == '\n') 2 else 1;
    if (c == '0' and (source.len == 1 or !std.ascii.isDigit(source[1]))) return 1;
    if (c == 'x' or c == 'u') {
        var end: usize = if (c == 'x') 3 else 5;
        var start: usize = 1;
        const braced = c == 'u' and source.len > 1 and source[1] == '{';
        if (braced) {
            start = 2;
            end = std.mem.indexOfScalar(u8, source, '}') orelse return 0;
        }
        if (end > source.len or end == start) return 0;
        for (source[start..end]) |digit| if (!std.ascii.isHex(digit)) return 0;
        if (braced and (std.fmt.parseInt(u32, source[start..end], 16) catch return 0) > 0x10ffff) return 0;
        return end + @intFromBool(braced);
    }
    if (source.len >= 3 and source[0] == 0xe2 and source[1] == 0x80 and (source[2] == 0xa8 or source[2] == 0xa9)) return 3;
    return 0;
}
fn componentName(allocator: Allocator, filename: ?[]const u8) ![]const u8 {
    const file = filename orelse return "$$Component";
    const base = file[(if (std.mem.lastIndexOfScalar(u8, file, '/')) |i| i + 1 else 0)..];
    const stem = base[0 .. std.mem.indexOfScalar(u8, base, '.') orelse base.len];
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(allocator, "$$");
    var upper = true;
    for (stem) |c| {
        if (!std.ascii.isAlphanumeric(c)) {
            upper = true;
            continue;
        }
        try out.append(allocator, if (upper) std.ascii.toUpper(c) else c);
        upper = false;
    }
    return if (out.items.len == 2 or text.eql(out.items, "$$Astro")) "$$Component" else out.toOwnedSlice(allocator);
}
fn scopeHash(allocator: Allocator, filename: []const u8, source: []const u8) ![]const u8 {
    var hash = std.crypto.auth.siphash.SipHash64(1, 3).init(&@as([16]u8, @splat(0)));
    hash.update(if (text.eql(filename, "<stdin>")) source else filename);
    hash.update(&.{0xff});
    var number = hash.finalInt();
    const out = try allocator.alloc(u8, 8);
    for (out) |*c| {
        c.* = "abcdefghijklmnopqrstuvwxyz234567"[@intCast(number & 31)];
        number >>= 5;
    }
    return out;
}
fn collapse(allocator: Allocator, source: []const u8, lone: bool, in_head: bool) ![]const u8 {
    const trimmed = std.mem.trim(u8, source, " \t\r\n\x0b\x0c");
    if (trimmed.len == 0) return if (lone or in_head) "" else " ";
    const start = @intFromPtr(trimmed.ptr) - @intFromPtr(source.ptr);
    const end = start + trimmed.len;
    const leading = if (start == 0) "" else if (std.mem.indexOfScalar(u8, source[0..start], '\n') != null) "\n" else " ";
    const trailing = if (end == source.len) "" else if (std.mem.indexOfScalar(u8, source[end..], '\n') != null) "\n" else " ";
    return std.mem.concat(allocator, u8, &.{ leading, trimmed, trailing });
}

fn collapseJsx(allocator: Allocator, source: []const u8) ![]const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    var start: usize = 0;
    var pos: usize = 0;
    while (pos < source.len) : (pos += 1) {
        if (source[pos] != '\r' and source[pos] != '\n') continue;
        try lines.append(allocator, source[start..pos]);
        if (source[pos] == '\r' and pos + 1 < source.len and source[pos + 1] == '\n') pos += 1;
        start = pos + 1;
    }
    try lines.append(allocator, source[start..]);
    var last: usize = 0;
    for (lines.items, 0..) |line, i| if (std.mem.trim(u8, line, " \t").len > 0) {
        last = i;
    };
    var output: std.ArrayList(u8) = .empty;
    try output.ensureTotalCapacity(allocator, source.len);
    for (lines.items, 0..) |line, i| {
        const left = if (i == 0) line else std.mem.trimStart(u8, line, " \t");
        const trimmed = if (i + 1 == lines.items.len) left else std.mem.trimEnd(u8, left, " \t");
        if (trimmed.len == 0) continue;
        for (trimmed) |c| try output.append(allocator, if (c == '\t') ' ' else c);
        if (i != last) try output.append(allocator, ' ');
    }
    return output.toOwnedSlice(allocator);
}
