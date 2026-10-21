const std = @import("std");
const yuku = @import("parser");
const t = @import("astro_types.zig");
const lex = @import("js_lexical.zig");
const raw_yuku = @import("yuku_tree.zig");
const editor_lex = @import("editor_lexical.zig");
const parser_state = @import("parser_state.zig");
const Allocator = std.mem.Allocator;
const Error = error{OutOfMemory};
pub const Mode = struct { expressions: bool = true, stop_at_brace: bool = false, jsx: bool = false };
const ProgramRead = struct { tree: yuku.ast.Tree };
const ExpressionRead = struct {
    tree: yuku.ast.Tree,
    next: @FieldType(yuku.ExpressionResult, "next"),
    delimiter_diagnostic: ?usize,
};

pub const Document = struct {
    allocator: Allocator,
    source: []const u8,
    limit: usize,
    cursor: usize = 0,
    depth: usize = 0,
    nodes: std.ArrayList(t.AstroNode) = .empty,
    roots: std.ArrayList(u32) = .empty,
    diagnostics: std.ArrayList(t.AstroDiagnostic) = .empty,
    diagnostic_origins: std.ArrayList(enum { markup, javascript }) = .empty,
    handled_diagnostics: std.ArrayList(yuku.ast.IndexRange) = .empty,
    stack: std.ArrayList([]const u8) = .empty,
    embedded: std.AutoHashMapUnmanaged(yuku.ast.NodeIndex, u32) = .empty,
    embedded_roots: std.ArrayList(yuku.ast.NodeIndex) = .empty,
    tree_nodes: std.ArrayList(yuku.ast.NodeIndex) = .empty,
    session: *@import("astro_parse.zig").ParseSession = undefined,
    active_children: ?*std.ArrayList(u32) = null,
    region: []const u8 = "template",
    frontmatter: ?t.AstroRegion = null,
    template_start: usize = 0,
    editor_mode: bool = false,
    preserve_script_trivia: bool = false,
    attribute_void: bool = false,
    collect_tokens: bool = true,
    /// Style preprocessing follows the reference's ordinary JSX frontmatter.
    standard_frontmatter_jsx: bool = false,
    javascript_roots: std.ArrayList(?u32) = .empty,
    type_argument_roots: std.ArrayList(?u32) = .empty,
    js_comments: std.ArrayList(std.json.Value) = .empty,
    frontmatter_root: ?u32 = null,
    frontmatter_fence_end: u32 = 0,
    fatal_markup: bool = false,
    fatal_root: ?u32 = null,
    halt_body: bool = false,
    body_parser: *yuku.Parser = undefined,
    // borrowed only while a dialect hook is active
    expression_parser: ?*yuku.dialect.Parser = null,
    reported_diagnostics: usize = 0,

    pub fn init(self: *Document, allocator: Allocator, source: []const u8) void {
        std.debug.assert(source.len <= std.math.maxInt(u32));
        self.* = .{ .allocator = allocator, .source = source, .limit = source.len };
        std.debug.assert(self.cursor == 0);
    }

    pub fn parse(self: *Document) Error!void {
        try self.reserveAstroTables(@intCast(@min(16_384, @max(8, self.source.len / 16))));
        if (self.limit > std.math.maxInt(u32)) {
            try self.report("Source exceeds the supported 32-bit byte range", 0, 0);
            return;
        }
        var opening: usize = if (std.mem.startsWith(u8, self.source, "\xef\xbb\xbf")) 3 else 0;
        while (opening < self.limit and std.ascii.isWhitespace(self.source[opening])) : (opening += 1) {}
        if (!self.editor_mode) opening = findOpeningFence(self.source) orelse self.limit;
        if (self.at(opening, "---")) {
            const begin = opening + 3;
            const maybe_end = if (self.editor_mode) editor_lex.frontmatterEnd(self.source, begin) else findClosingFence(self.source, begin);
            if (!self.editor_mode and maybe_end == null) {
                try self.body(&self.roots, null, .{});
                return;
            }
            const end = maybe_end orelse self.limit;
            if (end == self.limit) try self.report("Unclosed frontmatter fence", if (self.editor_mode) end else opening, self.limit);
            self.region = "frontmatter";
            var parsed = try self.readProgram(self.options(true), begin, end);
            const tree = &parsed.tree;
            try self.appendDiagnostics(null);
            self.frontmatter_root = @backingInt(tree.root);
            self.fatal_markup = false;
            self.halt_body = false;
            self.fatal_root = null;
            self.frontmatter = .{
                .start = @intCast(begin),
                .end = @intCast(end),
                .source = self.source[begin..end],
            };
            self.region = "template";
            self.frontmatter_fence_end = @intCast(@min(end + 3, self.limit));
            self.cursor = if (end < self.limit) end + 3 else end;
            if (self.cursor < self.limit and self.source[self.cursor] == '\r' and
                (self.editor_mode or (self.cursor + 1 < self.limit and self.source[self.cursor + 1] == '\n'))) self.cursor += 1;
            if (self.cursor < self.limit and self.source[self.cursor] == '\n') self.cursor += 1;
        }
        self.template_start = self.cursor;
        try self.body(&self.roots, null, .{});
    }

    pub fn options(self: *Document, allow_return: bool) yuku.Options {
        return .{
            .source_type = .module,
            .lang = if (self.editor_mode and allow_return) .ts else .tsx,
            .allow_return_outside_function = allow_return,
            .tokens = self.collect_tokens,
            .dialect = true,
        };
    }

    fn treeView(self: *Document, root: yuku.ast.NodeIndex, diagnostic_start: usize) yuku.ast.Tree {
        const session = self.body_parser;
        var view = session.tree.*;
        view.root = root;
        view.diagnostics = .{
            .items = session.diagnostics.items[diagnostic_start..],
            .capacity = session.diagnostics.items.len - diagnostic_start,
            .pointer_stability = .{},
        };
        return view;
    }

    fn readProgram(self: *Document, options_js: yuku.Options, begin: usize, end: usize) Error!ProgramRead {
        const session = self.body_parser;
        const diagnostic_start = session.diagnostics.items.len;
        var facade: yuku.dialect.Parser = .{ .inner = session };
        const parser = self.expression_parser orelse &facade;
        const pending_epoch = self.session.pending_epoch;
        const result = try parser.parseProgramRange(.{
            .start = @intCast(begin),
            .end = @intCast(end),
        }, options_js);
        try @import("embedded_markup.zig").connect(self, result.root, pending_epoch);
        if (self.editor_mode and options_js.allow_return_outside_function) {
            var parsed = self.treeView(result.root, diagnostic_start);
            parsed.lang = options_js.lang;
            parsed.source_type = options_js.source_type;
            parsed.diagnostics = .empty;
            try yuku.semantic.check(&parsed);
            try session.diagnostics.appendSlice(self.allocator, parsed.diagnostics.items);
        }
        return .{ .tree = self.treeView(result.root, diagnostic_start) };
    }

    fn readExpression(self: *Document, options_js: *const yuku.ExpressionOptions) Error!ExpressionRead {
        const session = self.body_parser;
        const diagnostic_start = session.diagnostics.items.len;
        if (session.range_depth >= 128 or self.session.candidate_depth >= 127) {
            try self.report("Embedded expression nesting exceeds parser limit", options_js.start, @min(options_js.start + 1, options_js.end.?));
            return .{
                .tree = self.treeView(.null, diagnostic_start),
                .next = yuku.ast.Token.eof(options_js.end.?),
                .delimiter_diagnostic = null,
            };
        }
        if (self.expression_parser) |facade| {
            const pending_epoch = self.session.pending_epoch;
            const parsed = try facade.parseExpressionRange(options_js);
            try @import("embedded_markup.zig").connect(self, parsed.root, pending_epoch);
            const delimiter_diagnostic = if (parsed.next.tag != (options_js.terminator orelse .eof) and parsed.metadata.diagnostics.len > 0)
                @as(usize, parsed.metadata.diagnostics.start) + parsed.metadata.diagnostics.len - 1
            else
                null;
            return .{
                .tree = self.treeView(parsed.root, diagnostic_start),
                .next = parsed.next,
                .delimiter_diagnostic = delimiter_diagnostic,
            };
        }
        const saved = try session.enterRange(.{ .start = options_js.start, .end = options_js.end.? }, options_js.options);
        defer session.leaveRange(&saved);
        const pending_epoch = self.session.pending_epoch;
        const root = try session.parseDelimitedExpression(options_js);
        try @import("embedded_markup.zig").connect(self, root, pending_epoch);
        const delimiter_diagnostic = if (session.current_token.tag != (options_js.terminator orelse .eof) and session.diagnostics.items.len > diagnostic_start)
            session.diagnostics.items.len - 1
        else
            null;
        return .{ .tree = self.treeView(root, diagnostic_start), .next = session.current_token, .delimiter_diagnostic = delimiter_diagnostic };
    }

    pub fn captureJavaScript(self: *Document, tree: *const yuku.ast.Tree) Error!std.json.Value {
        try self.captureComments(tree);
        var result = try raw_yuku.exportTree(self.allocator, tree);
        var markup_links = raw_yuku.array(self.allocator);
        var links = self.embedded.iterator();
        while (links.next()) |entry| {
            try markup_links.array.append(try raw_yuku.value(self.allocator, .{
                .node = @backingInt(entry.key_ptr.*),
                .astro_node = entry.value_ptr.*,
            }));
        }
        try raw_yuku.put(self.allocator, &result, "markup", markup_links);
        return result;
    }

    fn captureComments(self: *Document, tree: *const yuku.ast.Tree) Error!void {
        for (tree.comments) |comment| {
            try self.js_comments.append(self.allocator, try raw_yuku.value(self.allocator, .{
                .type = comment.type,
                .span = comment.span,
                .value = tree.string(comment.value),
            }));
        }
    }

    fn expressionIsSpread(self: *const Document, begin: usize) bool {
        var cursor = begin + 1;
        while (cursor < self.limit and std.ascii.isWhitespace(self.source[cursor])) : (cursor += 1) {}
        return self.at(cursor, "...");
    }

    fn body(self: *Document, children: *std.ArrayList(u32), parent: ?[]const u8, mode: Mode) Error!void {
        while (self.cursor < self.limit) {
            if (mode.stop_at_brace and self.source[self.cursor] == '}') return;
            if (self.editor_mode and mode.stop_at_brace and parent == null) {
                if (lex.commentEnd(self.source, self.cursor, self.limit)) |end| {
                    const begin = self.cursor;
                    self.cursor = end;
                    try children.append(self.allocator, try self.addNode("JsComment", begin, end));
                    continue;
                }
            }
            if (parent == null and self.isClosingTagStart(self.cursor)) {
                if (self.editor_mode and children == &self.roots) {
                    try children.append(self.allocator, try self.closingTag(true));
                    continue;
                }
                return;
            }
            if (!self.editor_mode and mode.expressions and !mode.stop_at_brace and self.source[self.cursor] == '}') {
                if (parent != null) {
                    try self.report("Unexpected token", self.cursor, self.cursor + 1);
                    self.fatal_markup = true;
                    return;
                }
                self.cursor += 1;
                try self.resumeJsToken(false);
                continue;
            }
            if (parent) |name| {
                if (!self.editor_mode and self.at(self.cursor, "</") and self.closingElement(self.cursor) == null) {
                    try self.report("Malformed closing tag", self.cursor, @min(self.cursor + 2, self.limit));
                    self.fatal_markup = true;
                    return;
                }
                if (self.closingElement(self.cursor)) |closing| {
                    if ((self.editor_mode and (mode.jsx or name.len == 0)) or std.mem.eql(u8, name, closing.name) or (!self.editor_mode and self.isAncestor(closing.name))) return;
                }
            }
            const before = self.cursor;
            const id = if (mode.expressions and self.source[self.cursor] == '{')
                try self.expression(self.expressionIsSpread(self.cursor), null, true)
            else if ((self.isMarkup(self.cursor) or (self.editor_mode and mode.jsx and self.at(self.cursor, "<")))) blk: {
                break :blk try self.markup(mode);
            } else blk: {
                self.cursor += 1;
                while (self.cursor < self.limit) {
                    if (mode.expressions and self.source[self.cursor] == '{') break;
                    if (mode.stop_at_brace and self.source[self.cursor] == '}') break;
                    if (!self.editor_mode and mode.expressions and self.source[self.cursor] == '}') break;
                    if (self.editor_mode and mode.stop_at_brace and parent == null and lex.commentEnd(self.source, self.cursor, self.limit) != null) break;
                    if (parent) |name| {
                        if (self.closingElement(self.cursor)) |closing| {
                            if ((self.editor_mode and (mode.jsx or name.len == 0)) or std.mem.eql(u8, name, closing.name) or (!self.editor_mode and self.isAncestor(closing.name))) break;
                        }
                    }
                    if ((self.isMarkup(self.cursor) or (self.editor_mode and mode.jsx and self.at(self.cursor, "<")))) break;
                    if (self.source[self.cursor] == '<' and self.source[before] != '<') break;
                    self.cursor += 1;
                }
                if (self.editor_mode and mode.jsx and mode.expressions) {
                    for (self.source[before..self.cursor], before..) |character, position| {
                        if (character == '}') try self.report("Unexpected closing brace in JSX text", position, position + 1);
                    }
                }
                break :blk try self.addText(before, self.cursor, !mode.expressions);
            };
            const kind = self.nodes.items[id].type_name;
            if (!std.mem.eql(u8, kind, "Ignored") and !(!self.editor_mode and std.mem.eql(u8, kind, "ClosingTag"))) try children.append(self.allocator, id);
            if (self.cursor <= before) self.cursor = before + 1;
            if (self.fatal_markup) {
                if (children == &self.roots) self.fatal_root = id;
                return;
            }
            if (self.halt_body) return;
        }
    }

    fn standardJsx(self: *const Document, embedded: bool) bool {
        return self.standard_frontmatter_jsx and embedded and std.mem.eql(u8, self.region, "frontmatter");
    }

    pub fn markup(self: *Document, mode: Mode) Error!u32 {
        const begin = self.cursor;
        if (self.standardJsx(mode.jsx) and (self.at(begin, "<!") or self.at(begin, "<?"))) try self.report("Unexpected JSX declaration", begin, @min(begin + 2, self.limit));
        if (self.at(begin, "<!--")) {
            const end = std.mem.indexOfPos(u8, self.source[0..self.limit], begin + 4, "-->");
            self.cursor = if (end) |position| position + 3 else self.limit;
            if (end == null) {
                if (self.stack.items.len > 0 or mode.stop_at_brace) {
                    try self.report("Unexpected token", begin + 1, @min(begin + 2, self.limit));
                    self.fatal_markup = true;
                }
                return self.addNode("Ignored", begin, self.cursor);
            }
            if (end == null) try self.report("Unclosed HTML comment", begin, self.cursor);
            const id = try self.addNode("Comment", begin, self.cursor);
            self.nodes.items[id].value = self.source[begin + 4 .. end orelse self.limit];
            self.nodes.items[id].value_start = @intCast(begin + 4);
            self.nodes.items[id].value_end = @intCast(end orelse self.limit);
            return id;
        }
        if (self.editor_mode and self.at(begin, "<![CDATA[")) {
            self.cursor = if (std.mem.indexOfPos(u8, self.source[0..self.limit], begin + 9, "]]>")) |close| close + 3 else self.limit;
            return self.addNode("Declaration", begin, self.cursor);
        }
        if (!self.editor_mode and self.at(begin, "<![CDATA[")) {
            self.cursor = begin + 2;
            try self.report("Unexpected token", begin + 1, begin + 2);
            self.fatal_markup = true;
            return self.addNode("Ignored", begin, self.cursor);
        }
        if (self.at(begin, "<!") or self.at(begin, "<?")) {
            const allow_gt_in_quotes = self.editor_mode or self.at(begin, "<?");
            self.cursor += 2;
            while (self.cursor < self.limit and self.source[self.cursor] != '>') {
                if (self.source[self.cursor] == '\'' or self.source[self.cursor] == '"') {
                    const quote = self.source[self.cursor];
                    self.cursor += 1;
                    while (self.cursor < self.limit and self.source[self.cursor] != quote and (allow_gt_in_quotes or self.source[self.cursor] != '>')) : (self.cursor += 1) {}
                    if (self.cursor < self.limit and self.source[self.cursor] == quote) self.cursor += 1;
                } else self.cursor += 1;
            }
            if (self.cursor < self.limit) self.cursor += 1 else try self.report("Unclosed markup declaration", begin, self.cursor);
            const id = try self.addNode(if (self.at(begin, "<!")) "Doctype" else "Declaration", begin, self.cursor);
            const content_finish = if (self.cursor > begin and self.source[self.cursor - 1] == '>') self.cursor - 1 else self.cursor;
            const offset = if (self.at(begin, "<!doctype") or self.at(begin, "<!DOCTYPE")) begin + 9 else begin + 2;
            self.nodes.items[id].value = std.mem.trim(u8, self.source[@min(offset, content_finish)..content_finish], " \t\r\n");
            return id;
        }
        if (self.isClosingTagStart(begin)) return self.closingTag(true);
        return self.element(mode);
    }

    /// Preserve malformed end tags as syntax nodes. Recovery stops before a
    /// following element or expression so the normal parser can resume there.
    fn closingTag(self: *Document, unexpected: bool) Error!u32 {
        const begin = self.cursor;
        const closing = self.closingName(begin);
        const name_start = begin + 2;
        const name_end = self.elementNameEnd(name_start);
        if (closing) |tag| {
            self.cursor = tag.end;
        } else {
            self.cursor = name_start;
            while (self.cursor < self.limit and std.mem.indexOfScalar(u8, "<>{}", self.source[self.cursor]) == null) : (self.cursor += 1) {}
            if (self.at(self.cursor, ">")) self.cursor += 1;
        }
        const id = try self.addNode("ClosingTag", begin, self.cursor);
        self.nodes.items[id].name = self.source[name_start..@min(name_end, self.cursor)];
        if (self.editor_mode) {
            self.nodes.items[id].name_start = @intCast(name_start);
            self.nodes.items[id].name_end = @intCast(@min(name_end, self.cursor));
            self.nodes.items[id].closed = closing != null;
        }
        if (unexpected) try self.report(if (closing != null) "Unexpected closing tag" else "Malformed closing tag", begin, self.cursor);
        if (self.editor_mode and unexpected and closing == null and self.cursor == self.limit) try self.report("Unclosed closing tag", self.cursor, self.cursor);
        return id;
    }

    fn element(self: *Document, inherited: Mode) Error!u32 {
        const begin = self.cursor;
        if (self.depth >= 128) {
            try self.report("Markup nesting exceeds the supported depth of 128", begin, begin);
            self.cursor += 1;
            while (self.cursor < self.limit and self.source[self.cursor] != '>') : (self.cursor += 1) {}
            if (self.cursor < self.limit) self.cursor += 1;
            return self.addText(begin, self.cursor, true);
        }
        self.depth += 1;
        defer self.depth -= 1;
        self.cursor += 1;
        if (self.editor_mode and inherited.jsx) self.skipWhitespace();
        const name_begin = self.cursor;
        if (self.editor_mode) self.cursor = self.editorElementNameEnd(self.cursor) else self.cursor = self.elementNameEnd(self.cursor);
        const name = self.source[name_begin..self.cursor];
        const fragment = name.len == 0 or std.mem.eql(u8, name, "Fragment");
        const component = !fragment and isComponent(name);
        const id = try self.addNode(if (fragment) "Fragment" else if (component) "Component" else if (std.ascii.eqlIgnoreCase(name, "script")) "Script" else if (std.ascii.eqlIgnoreCase(name, "style")) "Style" else "Element", begin, self.cursor);
        defer if (!self.editor_mode) {
            const node = &self.nodes.items[id];
            node.parse_failed = self.fatal_markup or !node.closed or node.opening_end == null or
                (!node.implicit_void and node.opening_end.? > 0 and self.source[node.opening_end.? - 1] != '>');
        };
        self.nodes.items[id].name = if (name.len == 0) null else name;
        self.nodes.items[id].name_start = @intCast(name_begin);
        self.nodes.items[id].name_end = @intCast(self.cursor);
        if (!std.mem.eql(u8, name, "script")) {
            try self.skipTagTrivia();
            if (self.editor_mode and !inherited.jsx and self.at(self.cursor, "<")) return self.bogusOpeningTag(id);
            if (self.cursor < self.limit and self.source[self.cursor] == '<' and (!self.editor_mode or inherited.jsx or !self.at(self.cursor, "</"))) {
                try self.typeArguments(id, self.editor_mode and inherited.jsx);
                if (self.editor_mode and inherited.jsx and self.fatal_markup) {
                    try self.report("Unclosed opening tag", self.cursor, self.cursor);
                    self.nodes.items[id].opening_end = @intCast(self.cursor);
                    self.nodes.items[id].closed = false;
                    self.updateSpan(id, self.cursor);
                    return id;
                }
            }
        }
        var attributes: std.ArrayList(t.AstroAttribute) = .empty;
        errdefer attributes.deinit(self.allocator);
        const previous_attribute_void = self.attribute_void;
        self.attribute_void = !component and !fragment and isVoidTagExact(name);
        defer self.attribute_void = previous_attribute_void;
        var self_closing = false;
        var has_gt = false;
        while (self.cursor < self.limit) {
            try self.skipTagTrivia();
            if (self.editor_mode and self.at(self.cursor, "<")) return self.bogusOpeningTag(id);
            if (self.at(self.cursor, "/>")) {
                self.cursor += 2;
                self_closing = true;
                has_gt = true;
                break;
            }
            if (self.editor_mode and self.at(self.cursor, "/")) {
                self.cursor += 1;
                self.skipWhitespace();
                self_closing = true;
                if (self.at(self.cursor, ">")) {
                    self.cursor += 1;
                    has_gt = true;
                    break;
                }
                try self.report("Expected opening tag delimiter", self.cursor, @min(self.cursor + 1, self.limit));
                self.nodes.items[id].self_closing = true;
                self.nodes.items[id].opening_end = null;
                self.nodes.items[id].closed = false;
                self.updateSpan(id, self.cursor);
                if (self.cursor == self.limit) self.fatal_markup = true;
                return id;
            }
            if (self.at(self.cursor, ">")) {
                self.cursor += 1;
                has_gt = true;
                break;
            }
            if (self.cursor == self.limit) break;
            const before = self.cursor;
            try attributes.append(self.allocator, try self.attribute(inherited.jsx));
            if (self.cursor <= before) self.cursor = before + 1;
        }
        self.nodes.items[id].attributes = try attributes.toOwnedSlice(self.allocator);
        self.nodes.items[id].self_closing = self_closing;
        self.nodes.items[id].implicit_void = !component and !fragment and isVoidTagExact(name) and !self_closing;
        if (!self.editor_mode) has_gt = self.cursor > begin and self.source[self.cursor - 1] == '>';
        self.nodes.items[id].opening_end = if (has_gt or !self.editor_mode) @intCast(self.cursor) else null;
        if (!has_gt) {
            if (!self.fatal_markup) try self.report("Unclosed opening tag", if (self.editor_mode) self.cursor else begin, self.cursor);
            if (self.editor_mode) self.fatal_markup = true;
        }
        if (self_closing or self.nodes.items[id].implicit_void or !has_gt) {
            self.updateSpan(id, self.cursor);
            if (std.mem.eql(u8, name, "script") and self_closing and isJavaScriptCompat(self.nodes.items[id])) {
                self.nodes.items[id].value_start = @intCast(self.cursor);
                self.nodes.items[id].value_end = @intCast(self.cursor);
                var script_options = self.options(false);
                script_options.lang = .ts;
                const parsed = try self.readProgram(script_options, self.cursor, self.cursor);
                self.javascript_roots.items[id] = @backingInt(parsed.tree.root);
            }
            return id;
        }
        try self.stack.append(self.allocator, name);
        defer _ = self.stack.pop();
        var children: std.ArrayList(u32) = .empty;
        errdefer children.deinit(self.allocator);
        const value_begin = self.cursor;
        const script = std.mem.eql(u8, name, "script");
        const style = std.mem.eql(u8, name, "style");
        const is_raw = hasAttribute(self.nodes.items[id], "is:raw");
        const jsx_content = self.standardJsx(inherited.jsx);
        if ((script or style or is_raw) and !jsx_content) {
            while (self.cursor < self.limit) : (self.cursor += 1) {
                if (self.closingName(self.cursor)) |closing| if (if (self.editor_mode) namesMatch(name, closing.name) else std.mem.startsWith(u8, closing.name, name)) break;
            }
            if (self.cursor > value_begin or (script and !isJavaScriptCompat(self.nodes.items[id]))) try children.append(self.allocator, try self.addText(value_begin, self.cursor, true));
            self.nodes.items[id].raw = true;
            self.nodes.items[id].value = self.source[value_begin..self.cursor];
            self.nodes.items[id].value_start = @intCast(value_begin);
            self.nodes.items[id].value_end = @intCast(self.cursor);
            if (script and isJavaScriptCompat(self.nodes.items[id])) {
                var opts = self.options(false);
                opts.lang = .ts;
                var parsed = try self.readProgram(opts, value_begin, self.cursor);
                const tree = &parsed.tree;
                try self.appendDiagnostics(null);
                self.javascript_roots.items[id] = @backingInt(tree.root);
            }
        } else {
            try self.body(&children, name, .{
                .expressions = if ((self.editor_mode and inherited.jsx) or jsx_content) true else inherited.expressions and !std.mem.eql(u8, name, "math"),
                .jsx = inherited.jsx,
            });
            if (jsx_content and (script or style)) {
                self.nodes.items[id].value = self.source[value_begin..self.cursor];
                self.nodes.items[id].value_start = @intCast(value_begin);
                self.nodes.items[id].value_end = @intCast(self.cursor);
            }
        }
        self.nodes.items[id].children = try children.toOwnedSlice(self.allocator);
        if (self.closingElement(self.cursor)) |closing| {
            if ((self.editor_mode and (inherited.jsx or name.len == 0)) or (if (!self.editor_mode and self.nodes.items[id].raw) std.mem.startsWith(u8, closing.name, name) else std.mem.eql(u8, name, closing.name))) {
                const missing_name = self.editor_mode and inherited.jsx and !fragment and closing.name.len == 0 and !closing.closed;
                if (self.editor_mode and inherited.jsx and !std.mem.eql(u8, name, closing.name)) {
                    if (missing_name) try self.report("Expected closing element name", self.cursor + 2, self.cursor + 2) else try self.report("Expected corresponding JSX closing tag", begin, self.nodes.items[id].opening_end.?);
                } else if (self.editor_mode and fragment and name.len == 0 and closing.name.len > 0) {
                    try self.report("Expected fragment closing delimiter", self.cursor + 2, self.cursor + 2 + closing.name.len);
                }
                self.nodes.items[id].closing_start = @intCast(self.cursor);
                self.nodes.items[id].closing_end = @intCast(closing.end);
                self.nodes.items[id].closing_name_start = @intCast(self.cursor + 2);
                self.nodes.items[id].closing_name_end = @intCast(self.cursor + 2 + closing.name.len);
                self.nodes.items[id].closed = closing.closed;
                if (!self.editor_mode and self.source[closing.end - 1] == ':') {
                    try self.report("Expected closing tag delimiter", closing.end - 1, closing.end);
                    self.halt_body = true;
                }
                self.cursor = closing.end;
                if (self.editor_mode and !closing.closed) {
                    if (!missing_name) try self.report("Unclosed closing tag", self.cursor, @min(self.cursor + 1, self.limit));
                    if (self.cursor == self.limit or self.at(self.cursor, "}")) self.fatal_markup = true;
                }
            } else {
                self.nodes.items[id].closed = false;
                try self.report("Unexpected token", self.cursor, self.cursor);
                if (!self.editor_mode) self.fatal_markup = true;
                self.cursor = closing.end;
                self.updateSpan(id, self.cursor);
                return id;
            }
        } else self.nodes.items[id].closed = false;
        if (!self.editor_mode and self.nodes.items[id].raw and !script and !self.nodes.items[id].closed) {
            // The reference retains an unfinished raw element and a recovered
            // closing tag. Its ordinary token reader advances once after EOF
            // fails to provide a raw-text closing tag.
            const session = self.body_parser;
            const saved = try session.enterRange(.{ .start = @intCast(value_begin), .end = @intCast(self.limit) }, self.options(false));
            defer session.leaveRange(&saved);
            _ = try session.advance();
            self.cursor = session.current_token.span.end;
            self.nodes.items[id].children = &.{};
            self.nodes.items[id].closing_start = self.nodes.items[id].opening_end.? - 1;
            self.nodes.items[id].closing_end = @intCast(self.cursor);
            self.nodes.items[id].closing_name_start = 0;
            self.nodes.items[id].closing_name_end = 0;
            try self.report("Unexpected token", session.current_token.span.start, self.cursor);
            self.fatal_markup = true;
            self.halt_body = true;
        }
        if (!self.nodes.items[id].closed and !self.fatal_markup and !(self.editor_mode and self.nodes.items[id].closing_start != null)) {
            try self.report(if (self.editor_mode) "Expected closing tag" else "Unexpected token", self.cursor, self.cursor);
            self.fatal_markup = true;
        }
        self.updateSpan(id, self.cursor);
        return id;
    }

    fn bogusOpeningTag(self: *Document, id: u32) Error!u32 {
        try self.report("Expected attribute", self.cursor, @min(self.cursor + 1, self.limit));
        if (self.at(self.cursor, "<") and !self.at(self.cursor, "</")) {
            var next = self.cursor + 1;
            var nested = false;
            while (next < self.limit and self.source[next] != '>') : (next += 1) {
                if (self.source[next] == '<') {
                    try self.report("Expected attribute", next, next + 1);
                    nested = true;
                }
            }
            if (nested and next < self.limit) {
                const name = self.nodes.items[id].name orelse "";
                var close = next + 1;
                const matched = while (close < self.limit) : (close += 1) {
                    if (self.closingName(close)) |tag| if (std.mem.eql(u8, name, tag.name)) break true;
                } else false;
                if (!matched) try self.report("Expected closing tag", self.limit, self.limit);
            }
        }
        if (self.closingName(self.cursor)) |closing| {
            const name = self.nodes.items[id].name orelse "";
            self.cursor = closing.end;
            if (!std.mem.eql(u8, name, closing.name)) {
                while (self.closingName(self.cursor)) |next| {
                    try self.report("Expected matching closing tag", self.cursor, next.end);
                    self.cursor = next.end;
                }
                try self.report("Expected closing tag", self.cursor, self.cursor);
                self.fatal_markup = true;
            }
        } else self.fatal_markup = true;
        var name_end = self.nodes.items[id].start.? + 1;
        while (name_end < self.cursor and !std.ascii.isWhitespace(self.source[name_end])) : (name_end += 1) {
            if (self.source[name_end] >= 128) self.nodes.items[id].type_name = "Text";
        }
        self.nodes.items[id].opening_end = null;
        self.nodes.items[id].closed = false;
        self.updateSpan(id, self.cursor);
        return id;
    }

    fn typeArguments(self: *Document, id: u32, editor_jsx: bool) Error!void {
        var options_ts = self.options(false);
        options_ts.lang = .ts;
        const session = self.body_parser;

        if (session.range_depth >= 127) {
            try self.report("Embedded type nesting exceeds parser limit", self.cursor, self.cursor);
            self.fatal_markup = true;
            self.cursor = self.limit;
            return;
        }
        const name_start = self.nodes.items[id].name_start orelse @as(u32, @intCast(self.cursor));
        const saved = try session.enterRange(.{ .start = name_start, .end = @intCast(self.limit) }, options_ts);
        defer session.leaveRange(&saved);
        var facade: yuku.dialect.Parser = .{ .inner = session };
        const closing_tag = editor_jsx and facade.tokenAt(@intCast(self.cursor + 1)).tag == .slash;
        const end = if (closing_tag) @as(u32, @intCast(self.limit)) else @import("embedded_markup.zig").angleEnd(&facade, @intCast(self.cursor), @intCast(self.limit)) orelse @as(u32, @intCast(self.limit));
        const bounded = try session.enterRange(.{ .start = name_start, .end = end }, options_ts);
        defer session.leaveRange(&bounded);
        const expression_root: yuku.ast.NodeIndex = if (closing_tag) invalid: {
            // A closing tag cannot start a type argument. Keep its slash out of JS regexp parsing.
            while (session.current_token.span.start < self.cursor) _ = try session.advance();
            _ = try session.advance();
            const slash = session.current_token;
            try self.report("Expected a type argument", slash.span.start, slash.span.end);
            break :invalid .null;
        } else try session.parseExpressionNode(yuku.Precedence.Lowest) orelse .null;
        const root: yuku.ast.NodeIndex = if (expression_root != .null and session.tree.data(expression_root) == .ts_instantiation_expression)
            session.tree.data(expression_root).ts_instantiation_expression.type_arguments
        else
            .null;
        self.cursor = if (root != .null) session.tree.span(root).end else session.current_token.span.end;
        try self.appendDiagnostics(null);
        if (editor_jsx and root == .null) {
            // Keep consuming the angle list after a bad argument, as the
            // reference JSX parser does, so the following `>` belongs to it.
            _ = try session.advance();
            while (session.current_token.tag != .greater_than and session.current_token.tag != .eof and session.current_token.tag != .right_brace) {
                const token = session.current_token;
                try self.report("Expected ',' between type arguments", token.span.start, token.span.end);
                _ = try session.advance();
            }
            self.cursor = session.current_token.span.end;
        }
        self.type_argument_roots.items[id] = @backingInt(root);
        if (root == .null) self.fatal_markup = true;
    }

    /// Skips JS tokens while recovering from a stray root brace.
    fn resumeJsToken(self: *Document, nested: bool) Error!void {
        const session = self.body_parser;
        const saved = try session.enterRange(.{ .start = @intCast(self.cursor), .end = @intCast(self.limit) }, self.options(false));
        defer session.leaveRange(&saved);
        try self.resumeJsTokenInner(session, nested);
    }

    fn resumeJsTokenInner(self: *Document, session: *yuku.Parser, nested: bool) Error!void {
        while (true) {
            const token = session.current_token;
            self.cursor = token.span.start;
            if (token.tag == .less_than or token.tag == .left_brace or token.tag == .right_brace or token.tag == .eof) break;
            if (nested) {
                try self.report("Unexpected token", token.span.start, token.span.end);
                self.fatal_markup = true;
                break;
            }
            if (try session.advance() == null) break;
        }
    }

    fn attribute(self: *Document, embedded: bool) Error!t.AstroAttribute {
        const begin = self.cursor;
        if (self.source[begin] == '{') {
            var start = begin + 1;
            while (start < self.limit and std.ascii.isWhitespace(self.source[start])) : (start += 1) {}
            const spread = self.at(start, "...");
            const id = try self.expression(spread, null, false);
            const node = self.nodes.items[id];
            const value = node.value orelse "";
            var name_start = node.value_start.?;
            var name_end = node.value_end.?;
            const trimmed = std.mem.trim(u8, self.source[name_start..name_end], " \t\r\n");
            const comment = !self.editor_mode and (self.javascript_roots.items[id] == null or self.javascript_roots.items[id].? == std.math.maxInt(u32)) and trimmed.len > 0;
            var simple_name = validShorthand(trimmed);
            if (self.editor_mode and embedded and !spread and !comment) {
                if (self.javascript_roots.items[id]) |root| if (root != std.math.maxInt(u32)) {
                    const parser = self.body_parser;
                    const root_id: yuku.ast.NodeIndex = @fromBackingInt(@intCast(root));
                    const data = parser.tree.data(root_id);
                    if ((data == .identifier_reference) or simple_name) {
                        const span = parser.tree.span(root_id);
                        name_start = span.start;
                        name_end = span.end;
                        simple_name = true;
                    }
                };
                if (!simple_name) {
                    const span: yuku.ast.Span = if (self.firstExpressionToken(node.value_start.?, node.value_end.?)) |token| token.span else .{ .start = node.value_end.?, .end = @min(node.value_end.? + 1, self.limit) };
                    try self.report("Expected a spread attribute", span.start, span.end);
                }
            }
            if (self.standardJsx(embedded) and !spread) try self.report("Expected a spread attribute", begin, self.cursor);
            return .{
                .kind = if (spread) "spread" else if (comment) "comment" else "shorthand",
                .name = if (spread or comment) null else if (self.editor_mode and embedded and simple_name) self.source[name_start..name_end] else trimmed,
                .value = value,
                .raw = self.source[begin..self.cursor],
                .start = @intCast(begin),
                .end = @intCast(self.cursor),
                .value_start = node.value_start,
                .value_end = node.value_end,
                .expression = id,
                .name_start = name_start,
                .name_end = name_end,
                .literal_start = @intCast(begin),
                .literal_end = @intCast(self.cursor),
            };
        }
        if (self.editor_mode and !embedded) {
            if (!htmlAttributeByte(self.source[self.cursor])) return self.invalidHtmlAttribute();
            while (self.cursor < self.limit and htmlAttributeByte(self.source[self.cursor])) : (self.cursor += 1) {}
        } else while (self.cursor < self.limit and !isNameEnd(self.source[self.cursor]) and self.source[self.cursor] != '=' and (self.source[self.cursor] != '{' and self.source[self.cursor] != '}')) : (self.cursor += 1) {}
        const name = self.source[begin..self.cursor];
        const name_end = self.cursor;
        if (name.len == 0) {
            self.cursor += 1;
            try self.report("Expected an attribute name", begin, self.cursor);
        }
        try self.skipTagTrivia();
        var result: t.AstroAttribute = .{ .kind = "boolean", .name = name, .raw = "", .start = @intCast(begin), .end = 0, .name_start = @intCast(begin), .name_end = @intCast(name_end) };
        if (self.at(self.cursor, "=")) {
            self.cursor += 1;
            self.skipWhitespace();
            const value_begin = self.cursor;
            result.literal_start = @intCast(value_begin);
            if (self.cursor == self.limit) {
                try self.report("Missing attribute value", if (self.editor_mode) self.cursor else begin, self.cursor);
                if (self.editor_mode) self.fatal_markup = true;
            } else if (self.source[self.cursor] == '{') {
                const diagnostic_start = self.diagnostics.items.len;
                const id = try self.expression(false, null, false);
                const node = self.nodes.items[id];
                result.kind = "expression";
                result.expression = id;
                result.value = node.value;
                result.value_start = node.value_start;
                result.value_end = node.value_end;
                if (self.editor_mode and embedded) for (self.diagnostics.items[diagnostic_start..]) |*diagnostic| {
                    if (diagnostic.start == node.value_end and diagnostic.end == node.value_end and self.at(node.value_end.?, "}")) diagnostic.end = node.value_end.? + 1;
                };
                if (self.editor_mode and embedded and self.javascript_roots.items[id] == std.math.maxInt(u32) and self.diagnostics.items.len == diagnostic_start and self.at(node.value_end.?, "}")) {
                    try self.report("Expected an attribute expression", node.value_end.?, node.value_end.? + 1);
                }
            } else if (self.source[self.cursor] == '`') {
                const end = lex.quotedEnd(self.source, self.cursor, self.limit);
                const id = try self.expression(false, end, false);
                result.kind = "template";
                result.expression = id;
                result.value = self.source[value_begin..end];
                result.value_start = @intCast(value_begin);
                result.value_end = @intCast(end);
            } else if (self.source[self.cursor] == '\'' or self.source[self.cursor] == '"') {
                const quote = self.source[self.cursor];
                self.cursor += 1;
                const content_begin = self.cursor;
                while (self.cursor < self.limit and self.source[self.cursor] != quote) : (self.cursor += 1) {}
                result.kind = "quoted";
                result.value = self.source[content_begin..self.cursor];
                result.value_start = @intCast(content_begin);
                result.value_end = @intCast(self.cursor);
                if (self.cursor < self.limit) self.cursor += 1 else try self.report("Unclosed quoted attribute", value_begin, self.cursor);
            } else {
                if (self.editor_mode and !embedded and self.source[self.cursor] >= 128) {
                    const end = self.cursor + (@import("tsx_text.zig").cpLen(self.source, self.cursor));
                    try self.report("Unexpected character in unquoted attribute value", self.cursor, end);
                    return self.invalidHtmlAttribute();
                }
                while (self.cursor < self.limit and !std.ascii.isWhitespace(self.source[self.cursor]) and self.source[self.cursor] != '>' and (if (self.editor_mode and !embedded) self.source[self.cursor] != '<' else self.source[self.cursor] != '{' and self.source[self.cursor] != '}' and self.source[self.cursor] != '<')) : (self.cursor += 1) {}
                result.kind = "unquoted";
                result.value = self.source[value_begin..self.cursor];
                result.value_start = @intCast(value_begin);
                result.value_end = @intCast(self.cursor);
                if (self.cursor == value_begin) try self.report("Missing attribute value", value_begin, self.cursor);
            }
            result.literal_end = @intCast(self.cursor);
        }
        result.end = @intCast(if (std.mem.eql(u8, result.kind, "boolean")) name_end else self.cursor);
        if (self.standardJsx(embedded) and (std.mem.eql(u8, result.kind, "unquoted") or std.mem.eql(u8, result.kind, "template"))) try self.report("JSX attribute values must be quoted or expressions", result.value_start orelse result.start, self.cursor);
        result.raw = self.source[begin..result.end];
        return result;
    }

    fn htmlAttributeByte(byte: u8) bool {
        return byte < 128 and !std.ascii.isControl(byte) and std.mem.indexOfScalar(u8, " \t\n\"'><=/", byte) == null;
    }

    fn invalidHtmlAttribute(self: *Document) Error!t.AstroAttribute {
        const begin = self.cursor;
        const byte = self.source[begin];
        if (byte == '\'' or byte == '"') {
            var end = begin + 1;
            while (end < self.limit and self.source[end] != byte) : (end += 1) {}
            if (end == self.limit) {
                try self.report("Missing closing quote", begin, end);
                self.cursor = end;
                return .{ .kind = "invalid", .raw = self.source[begin..end], .start = @intCast(begin), .end = @intCast(end) };
            }
        }
        var unexpected_character = false;
        if (byte >= 128) {
            unexpected_character = true;
            try self.report("Unexpected character", begin, begin + @import("tsx_text.zig").cpLen(self.source, begin));
        }
        self.cursor += @import("tsx_text.zig").cpLen(self.source, self.cursor);
        while (self.cursor < self.limit and !self.isMarkup(self.cursor)) : (self.cursor += 1) {}
        var end = self.cursor;
        while (end > begin and std.ascii.isWhitespace(self.source[end - 1])) : (end -= 1) {}
        if (!unexpected_character) try self.report("Expected attribute", begin, end);
        return .{ .kind = "invalid", .raw = self.source[begin..self.cursor], .start = @intCast(begin), .end = @intCast(self.cursor) };
    }

    fn expression(self: *Document, spread: bool, literal_end: ?usize, in_child: bool) Error!u32 {
        const begin = self.cursor;
        var value_begin = begin + @as(usize, if (literal_end == null) 1 else 0);
        if (spread) {
            while (value_begin < self.limit and std.ascii.isWhitespace(self.source[value_begin])) : (value_begin += 1) {}
            value_begin += 3;
        }
        const id = try self.addNode("Expression", begin, begin);
        self.nodes.items[id].spread = spread;
        const editor_end = if (self.editor_mode and literal_end == null) editor_lex.expressionEnd(self.source, value_begin, self.limit) else null;
        if (editor_end == self.limit) {
            var boundary = value_begin;
            while (boundary < self.limit and !self.isMarkup(boundary)) : (boundary += 1) {}
            var diagnostic_end = boundary;
            while (diagnostic_end > value_begin and std.ascii.isWhitespace(self.source[diagnostic_end - 1])) : (diagnostic_end -= 1) {}
            try self.report("Unclosed text expression", begin, @max(begin + 1, diagnostic_end));
            self.cursor = boundary;
            self.nodes.items[id].value = self.source[value_begin..boundary];
            self.nodes.items[id].value_start = @intCast(value_begin);
            self.nodes.items[id].value_end = @intCast(boundary);
            self.nodes.items[id].closed = false;
            self.updateSpan(id, boundary);
            return id;
        }
        var children: std.ArrayList(u32) = .empty;
        errdefer children.deinit(self.allocator);
        const saved_children = self.active_children;
        self.active_children = &children;
        defer self.active_children = saved_children;
        var significant = value_begin;
        while (significant < self.limit and std.ascii.isWhitespace(self.source[significant])) : (significant += 1) {}
        if (in_child and literal_end == null and !spread and self.isMarkup(significant)) {
            self.cursor = significant;
            {
                const limit = self.limit;
                defer self.limit = limit;
                if (editor_end) |end| self.limit = end;
                try self.body(&children, null, .{ .stop_at_brace = true, .jsx = true });
            }
            if (children.items.len > 0) {
                const last = self.nodes.items[children.items[children.items.len - 1]];
                if (std.mem.eql(u8, last.type_name, "Text") and std.mem.trim(u8, last.text, " \t\r\n").len == 0) _ = children.pop();
            }
            const value_end = self.cursor;
            if (self.cursor < self.limit and self.source[self.cursor] == '}') self.cursor += 1 else {
                self.nodes.items[id].closed = false;
                if (self.editor_mode) try self.reportUnclosedExpression(begin, value_begin) else try self.report("Unexpected token", self.cursor, self.cursor);
            }
            self.nodes.items[id].children = try children.toOwnedSlice(self.allocator);
            if (self.editor_mode) for (self.nodes.items[id].children) |child| {
                const value = self.nodes.items[child];
                if (std.mem.eql(u8, value.type_name, "Text") and
                    std.mem.trim(u8, value.text, " \t\r\n").len > 0)
                {
                    try self.report("Template expressions can only contain a single expression", value.start.?, value.end.?);
                    break;
                }
            };
            self.nodes.items[id].value = self.source[value_begin..value_end];
            self.nodes.items[id].value_start = @intCast(value_begin);
            self.nodes.items[id].value_end = @intCast(value_end);
            self.updateSpan(id, self.cursor);
            return id;
        }
        const expression_options: yuku.ExpressionOptions = .{
            .options = self.options(false),
            .start = @intCast(value_begin),
            .end = @intCast(editor_end orelse literal_end orelse self.limit),
            .terminator = if (literal_end != null or editor_end != null) .eof else .right_brace,
            .allow_empty = true,
        };
        const previous_fatal = self.fatal_markup;
        const previous_halt = self.halt_body;
        var parsed = try self.readExpression(&expression_options);
        var extra_closing_tag: ?usize = null;
        if (self.editor_mode and parsed.next.tag == .less_than) {
            var entries = self.embedded.iterator();
            while (entries.next()) |entry| {
                const span = self.body_parser.tree.span(entry.key_ptr.*);
                if (span.start >= value_begin and span.end == parsed.next.span.start and self.closingName(span.end) != null) {
                    extra_closing_tag = span.end;
                    break;
                }
            }
        }
        if (editor_end) |end| {
            parsed.next.tag = .right_brace;
            parsed.next.span = .{ .start = @intCast(end), .end = @intCast(end + 1) };
            self.fatal_markup = previous_fatal;
            self.halt_body = previous_halt;
        }
        var previous = begin;
        while (previous > 0 and std.ascii.isWhitespace(self.source[previous - 1])) : (previous -= 1) {}
        const editor_recovery = self.editor_mode and parsed.next.tag == .right_brace and parsed.tree.root == .null and
            !in_child and !spread and literal_end == null and previous > 0 and self.source[previous - 1] != '=';
        var template_return: ?yuku.ast.Span = null;
        if (self.editor_mode and in_child and literal_end == null and self.at(significant, "return")) {
            if (self.firstExpressionToken(value_begin, editor_end orelse self.limit)) |token| {
                if (token.tag == .@"return") template_return = token.span;
            }
        }
        if (editor_recovery or extra_closing_tag != null or template_return != null) {
            self.reported_diagnostics = self.body_parser.diagnostics.items.len;
            if (extra_closing_tag) |position| try self.report("Template expressions can only contain a single expression", position, position + 1);
            if (template_return) |span| {
                const message = for (parsed.tree.diagnostics.items) |diagnostic| {
                    if (diagnostic.span.start == span.start and diagnostic.span.end == span.end) break diagnostic.message;
                } else "Expected expression in template syntax";
                try self.report(message, span.start, span.end);
            }
        } else {
            const diagnostic_start = self.diagnostics.items.len;
            try self.appendDiagnostics(parsed.delimiter_diagnostic);
            if (self.editor_mode) for (self.diagnostics.items[diagnostic_start..]) |*diagnostic| {
                if (parsed.next.tag == .right_brace) {
                    diagnostic.start = @min(diagnostic.start orelse parsed.next.span.start, parsed.next.span.start);
                    diagnostic.end = @min(diagnostic.end orelse parsed.next.span.start, parsed.next.span.start);
                }
            };
        }
        if (self.depth == 0 and parsed.tree.root != .null and parsed.tree.hasErrors()) {
            if (parser_state.missingOperand(&parsed.tree, parsed.tree.root)) self.halt_body = true;
        }
        if (!self.editor_mode and !editor_recovery and parsed.tree.root == .null and parsed.tree.hasErrors() and self.depth > 0 and (self.editor_mode or !self.attribute_void)) self.fatal_markup = true;
        self.javascript_roots.items[id] = @backingInt(parsed.tree.root);
        var value_end: usize = if (literal_end) |end| end else parsed.next.span.start;
        if (literal_end) |end| {
            self.cursor = end;
        } else if (parsed.next.tag == .right_brace) {
            self.cursor = @min(value_end + 1, self.limit);
        } else {
            self.cursor = parsed.next.span.end;
            if (self.depth > 0 and (self.editor_mode or !self.attribute_void)) self.fatal_markup = true else self.halt_body = true;
        }
        value_end = @min(@max(value_end, value_begin), self.limit);
        self.nodes.items[id].value = self.source[value_begin..value_end];
        self.nodes.items[id].value_start = @intCast(value_begin);
        self.nodes.items[id].value_end = @intCast(value_end);
        self.nodes.items[id].children = try children.toOwnedSlice(self.allocator);
        self.updateSpan(id, self.cursor);
        return id;
    }

    fn reportUnclosedExpression(self: *Document, begin: usize, value_begin: usize) Error!void {
        var end = self.limit;
        for (self.nodes.items) |node| {
            if (isElementLike(node) and node.start.? >= value_begin and node.start.? + 1 < self.limit) {
                end = @min(end, node.start.?);
            }
        }
        while (end > value_begin and std.ascii.isWhitespace(self.source[end - 1])) : (end -= 1) {}
        try self.report("Unclosed text expression", begin, @max(begin + 1, end));
    }

    fn firstExpressionToken(self: *const Document, start: usize, end: usize) ?yuku.ast.Token {
        const parser = self.body_parser;
        var first: ?yuku.ast.Token = null;
        for (parser.tokens.items) |token| {
            if (token.tag == .eof or token.span.start < start or token.span.end > end) continue;
            if (first == null or token.span.start < first.?.span.start) first = token;
        }
        return first;
    }

    fn reserveAstroTables(self: *Document, capacity: u32) Error!void {
        std.debug.assert(capacity >= self.nodes.items.len);
        try self.nodes.ensureTotalCapacity(self.allocator, capacity);
        const actual_capacity = self.nodes.capacity;
        try self.tree_nodes.ensureTotalCapacity(self.allocator, actual_capacity);
        try self.javascript_roots.ensureTotalCapacity(self.allocator, actual_capacity);
        try self.type_argument_roots.ensureTotalCapacity(self.allocator, actual_capacity);
    }

    pub fn addNode(self: *Document, kind: []const u8, begin: usize, end: usize) Error!u32 {
        const id: u32 = @intCast(self.nodes.items.len);
        if (self.nodes.items.len == self.nodes.capacity) try self.reserveAstroTables(@intCast(self.nodes.items.len + 1));
        self.javascript_roots.appendAssumeCapacity(null);
        self.type_argument_roots.appendAssumeCapacity(null);
        self.nodes.appendAssumeCapacity(.{ .id = id, .type_name = kind, .start = @intCast(begin), .end = @intCast(end), .text = self.source[begin..end] });
        self.tree_nodes.appendAssumeCapacity(.null);
        return id;
    }

    fn addText(self: *Document, begin: usize, end: usize, raw: bool) Error!u32 {
        const id = try self.addNode("Text", begin, end);
        self.nodes.items[id].value = self.source[begin..end];
        self.nodes.items[id].raw = raw;
        return id;
    }

    fn updateSpan(self: *Document, id: u32, end: usize) void {
        self.nodes.items[id].end = @intCast(end);
        self.nodes.items[id].text = self.source[self.nodes.items[id].start.?..end];
    }

    fn report(self: *Document, message: []const u8, begin: usize, end: usize) Error!void {
        const owned = try self.allocator.dupe(u8, message);
        errdefer self.allocator.free(owned);
        try self.diagnostics.append(self.allocator, .{ .region = self.region, .severity = "error", .message = owned, .start = @intCast(begin), .end = @intCast(end) });
        try self.diagnostic_origins.append(self.allocator, .markup);
    }

    fn appendDiagnostics(self: *Document, delimiter_diagnostic: ?usize) Error!void {
        const items = self.body_parser.diagnostics.items[self.reported_diagnostics..];
        for (items, self.reported_diagnostics..) |diagnostic, index| {
            const handled = for (self.handled_diagnostics.items) |range| {
                if (index >= range.start and index - range.start < range.len) break true;
            } else false;
            if (handled) continue;
            if (self.editor_mode and items.len > 1 and delimiter_diagnostic == index) continue;
            const message = try self.allocator.dupe(u8, diagnostic.message);
            errdefer self.allocator.free(message);
            const help = if (diagnostic.help) |value| try self.allocator.dupe(u8, value) else null;
            errdefer if (help) |value| self.allocator.free(value);
            const labels = try self.allocator.alloc(t.DiagnosticLabel, diagnostic.labels.len);
            var initialized: usize = 0;
            errdefer {
                for (labels[0..initialized]) |label| self.allocator.free(label.message);
                self.allocator.free(labels);
            }
            for (diagnostic.labels, labels) |label, *owned| {
                owned.* = .{
                    .span = .{ .start = label.span.start, .end = label.span.end },
                    .message = try self.allocator.dupe(u8, label.message),
                };
                initialized += 1;
            }
            try self.diagnostics.append(self.allocator, .{
                .region = self.region,
                .severity = diagnostic.severity.toString(),
                .message = message,
                .start = diagnostic.span.start,
                .end = diagnostic.span.end,
                .help = help,
                .labels = labels,
            });
            try self.diagnostic_origins.append(self.allocator, .javascript);
        }
        self.reported_diagnostics = self.body_parser.diagnostics.items.len;
    }

    fn skipWhitespace(self: *Document) void {
        while (self.cursor < self.limit and std.ascii.isWhitespace(self.source[self.cursor])) : (self.cursor += 1) {}
    }

    fn skipTagTrivia(self: *Document) Error!void {
        while (true) {
            self.skipWhitespace();
            const begin = self.cursor;
            const line = self.at(begin, "//");
            if (!line and !self.at(begin, "/*")) return;
            const end = if (line) blk: {
                var position = begin + 2;
                while (position < self.limit and self.source[position] != '\n' and self.source[position] != '\r') : (position += 1) {}
                break :blk position;
            } else blk: {
                const close = std.mem.indexOfPos(u8, self.source[0..self.limit], begin + 2, "*/") orelse {
                    self.cursor = self.limit;
                    try self.report("Unterminated comment", begin, self.limit);
                    return;
                };
                break :blk close + 2;
            };
            try self.js_comments.append(self.allocator, try raw_yuku.value(self.allocator, .{
                .type = if (line) "line" else "block",
                .span = yuku.ast.Span{ .start = @intCast(begin), .end = @intCast(end) },
                .value = self.source[begin + 2 .. if (line) end else end - 2],
            }));
            self.cursor = end;
        }
    }

    fn at(self: *const Document, index: usize, value: []const u8) bool {
        return index <= self.limit and std.mem.startsWith(u8, self.source[index..self.limit], value);
    }

    fn atIgnoreCase(self: *const Document, index: usize, value: []const u8) bool {
        return index + value.len <= self.limit and std.ascii.eqlIgnoreCase(self.source[index .. index + value.len], value);
    }

    pub fn isMarkup(self: *const Document, index: usize) bool {
        if (index + 1 >= self.limit or self.source[index] != '<') return false;
        const c = self.source[index + 1];
        return std.ascii.isAlphabetic(c) or c == '>' or c == '!' or (self.editor_mode and c == '?') or (c == '/' and self.isClosingTagStart(index));
    }

    fn isClosingTagStart(self: *const Document, index: usize) bool {
        if (!self.at(index, "</")) return false;
        if (!self.editor_mode) return self.closingName(index) != null;
        // Outside an element, non-ASCII tag-looking text is ordinary Astro
        // text, just like a non-ASCII opening tag. Within an element an end-tag
        // opener is a recovery boundary even when its name is malformed.
        return self.stack.items.len > 0 or index + 2 == self.limit or std.ascii.isAscii(self.source[index + 2]);
    }

    fn elementNameEnd(self: *const Document, begin: usize) usize {
        var end = begin;
        while (true) {
            while (end < self.limit and !isNameEnd(self.source[end]) and (self.editor_mode or self.source[end] != ':') and self.source[end] != '.') : (end += 1) {}
            var dot = end;
            while (dot < self.limit and std.ascii.isWhitespace(self.source[dot])) : (dot += 1) {}
            if (dot == self.limit or self.source[dot] != '.') return end;
            end = dot + 1;
            while (end < self.limit and std.ascii.isWhitespace(self.source[end])) : (end += 1) {}
        }
    }

    fn editorElementNameEnd(self: *const Document, begin: usize) usize {
        var end = begin;
        while (true) {
            while (end < self.limit) {
                const c = self.source[end];
                if (!std.ascii.isAlphanumeric(c) and c != '_' and c != '$' and c != '-' and c != ':' and c < 128) break;
                end += 1;
            }
            var dot = end;
            while (dot < self.limit and std.ascii.isWhitespace(self.source[dot])) : (dot += 1) {}
            if (dot == self.limit or self.source[dot] != '.') return end;
            end = dot + 1;
            while (end < self.limit and std.ascii.isWhitespace(self.source[end])) : (end += 1) {}
        }
    }

    fn closingName(self: *const Document, index: usize) ?struct { name: []const u8, end: usize } {
        if (!self.at(index, "</")) return null;
        var end = index + 2;
        const begin = end;
        end = self.elementNameEnd(end);
        const name = self.source[begin..end];
        if (name.len > 0 and !std.ascii.isAlphabetic(name[0])) return null;
        while (end < self.limit and std.ascii.isWhitespace(self.source[end])) : (end += 1) {}
        if (end == self.limit or self.source[end] != '>') return null;
        return .{ .name = name, .end = end + 1 };
    }

    /// A named closing element can be present while its final '>' is still
    /// missing. Keep its ranges on the parent instead of turning it into text.
    fn closingElement(self: *const Document, index: usize) ?struct { name: []const u8, end: usize, closed: bool } {
        if (self.closingName(index)) |closing| return .{ .name = closing.name, .end = closing.end, .closed = true };
        if (!self.editor_mode and self.at(index, "</")) {
            const end = self.elementNameEnd(index + 2);
            if (end > index + 2 and end < self.limit and self.source[end] == ':') return .{ .name = self.source[index + 2 .. end], .end = end + 1, .closed = true };
        }
        if (!self.editor_mode or !self.at(index, "</")) return null;
        const name_start = index + 2;
        const name_end = self.editorElementNameEnd(name_start);
        const name = self.source[name_start..name_end];
        if (name.len > 0 and !std.ascii.isAlphabetic(name[0])) return null;
        var end = name_end;
        while (end < self.limit and std.ascii.isWhitespace(self.source[end])) : (end += 1) {}
        if (end != self.limit and !self.at(end, "<") and !self.at(end, "}")) return null;
        return .{ .name = name, .end = end, .closed = false };
    }

    fn isAncestor(self: *const Document, name: []const u8) bool {
        for (self.stack.items) |ancestor| if (std.mem.eql(u8, ancestor, name)) return true;
        return false;
    }
};

fn isNameEnd(c: u8) bool {
    return std.ascii.isWhitespace(c) or c == '/' or c == '>' or c == '<';
}
fn isComponent(name: []const u8) bool {
    return name.len > 0 and (std.ascii.isUpper(name[0]) or std.mem.indexOfScalar(u8, name, '.') != null);
}
fn namesMatch(a: []const u8, b: []const u8) bool {
    return if (isComponent(a) or isComponent(b)) std.mem.eql(u8, a, b) else std.ascii.eqlIgnoreCase(a, b);
}
fn validShorthand(name: []const u8) bool {
    if (name.len == 0 or std.ascii.isDigit(name[0])) return false;
    for (name) |c| if (!lex.isIdentifier(c)) return false;
    return true;
}

pub fn hasAttribute(node: t.AstroNode, name: []const u8) bool {
    for (node.attributes) |attribute| if (attribute.name) |value| if (std.mem.eql(u8, value, name)) return true;
    return false;
}

pub fn attributeValue(node: t.AstroNode, name: []const u8) ?[]const u8 {
    for (node.attributes) |attribute| if (attribute.name) |value| if (std.mem.eql(u8, value, name)) return attribute.value;
    return null;
}

fn isJavaScriptCompat(node: t.AstroNode) bool {
    for (node.attributes) |attribute| {
        if (attribute.name) |name| {
            if (!std.mem.eql(u8, name, "type")) continue;
            if (attribute.value == null or attribute.expression != null) return false;
            for ([_][]const u8{ "module", "text/javascript", "application/javascript", "text/ecmascript", "application/ecmascript", "application/x-javascript" }) |mime| {
                if (std.mem.eql(u8, attribute.value.?, mime)) return true;
            }
            return false;
        }
    }
    return true;
}

fn isElementLike(node: t.AstroNode) bool {
    for ([_][]const u8{ "Element", "Component", "Fragment", "Script", "Style" }) |kind| if (std.mem.eql(u8, node.type_name, kind)) return true;
    return false;
}

fn isVoidTagExact(name: []const u8) bool {
    for ([_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" }) |candidate| if (std.mem.eql(u8, name, candidate)) return true;
    return false;
}

fn findOpeningFence(source: []const u8) ?usize {
    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        if (source[i] == '<' or source[i] == '{' or source[i] == '}') return null;
        if (std.mem.startsWith(u8, source[i..], "---")) return i;
    }
    return null;
}

// The pinned compiler's fence scanner intentionally treats a template as one
// lexical state and treats a triple dash in Normal as a fence at any position.
// Keep this separate from the stricter native API's scanner.
fn findClosingFence(source: []const u8, begin: usize) ?usize {
    const State = enum { normal, single, double, template, line, block, regex, regex_class };
    var state: State = .normal;
    var regex_allowed = true;
    var i = begin;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        switch (state) {
            .normal => {
                if (std.mem.startsWith(u8, source[i..], "---")) return i;
                if (c == '\'') {
                    state = .single;
                } else if (c == '"') {
                    state = .double;
                } else if (c == '`') {
                    state = .template;
                } else if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
                    state = .line;
                    i += 1;
                } else if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
                    state = .block;
                    i += 1;
                } else if (c == '/' and regex_allowed) {
                    state = .regex;
                } else if (c == ')' or c == ']' or std.ascii.isAlphanumeric(c) or c == '_' or c == '$') {
                    regex_allowed = false;
                } else if (c != ' ' and c != '\t') regex_allowed = true;
            },
            .single, .double => {
                if (c == '\\' and i + 1 < source.len) {
                    i += 1;
                } else if ((state == .single and c == '\'') or (state == .double and c == '"')) {
                    state = .normal;
                    regex_allowed = false;
                } else if (c == '\n' or c == '\r') {
                    state = .normal;
                    regex_allowed = true;
                }
            },
            .template => if (c == '\\' and i + 1 < source.len) {
                i += 1;
            } else if (c == '`') {
                state = .normal;
                regex_allowed = false;
            },
            .line => if (c == '\n') {
                state = .normal;
                regex_allowed = true;
            },
            .block => if (c == '*' and i + 1 < source.len and source[i + 1] == '/') {
                i += 1;
                state = .normal;
            },
            .regex => if (c == '\\' and i + 1 < source.len) {
                i += 1;
            } else if (c == '[') {
                state = .regex_class;
            } else if (c == '/') {
                state = .normal;
                regex_allowed = false;
            } else if (c == '\n' or c == '\r') {
                state = .normal;
                regex_allowed = true;
            },
            .regex_class => if (c == '\\' and i + 1 < source.len) {
                i += 1;
            } else if (c == ']') {
                state = .regex;
            } else if (c == '\n' or c == '\r') {
                state = .normal;
                regex_allowed = true;
            },
        }
    }
    return null;
}
