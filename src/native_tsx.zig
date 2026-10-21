const std = @import("std");
const parse = @import("astro_parse.zig");
const ast = @import("astro_types.zig");
const analysis_module = @import("tsx_analysis.zig");
const print = @import("tsx_printer.zig");
const text = @import("tsx_text.zig");
const data = @import("tsx_data.zig");
const Allocator = std.mem.Allocator;
const Error = print.Error;
const Range = print.Range;
pub const Options = struct { filename: ?[]const u8 = null, ambient_types: bool = false };
pub const Result = struct {
    code: []const u8,
    mappings: []const []const u32,
    frontmatter: Range,
    body: Range,
    frontmatter_status: []const u8,
    frontmatter_source: Range,
    scripts: []const print.Script,
    styles: []const print.Style,
    generated_script_ranges: []const Range,
    generated_style_ranges: []const Range,
    diagnostics: []const print.Diagnostic,
    has_parse_errors: bool,
    generated_component_export: ?Range,
};

/// The caller supplies an arena covering all result strings and arrays.
/// WTF-8 input preserves unfinished UTF-16 units in emitted code and mappings.
pub fn convert(allocator: Allocator, source: []const u8, options: Options) !Result {
    const parser_source = if (std.unicode.utf8ValidateSlice(source)) source else blk: {
        const normalized = try allocator.dupe(u8, source);
        var i: usize = 0;
        while (i + 2 < normalized.len) {
            if (normalized[i] == 0xed and normalized[i + 1] >= 0xa0 and normalized[i + 1] <= 0xbf and normalized[i + 2] & 0xc0 == 0x80) {
                @memcpy(normalized[i..][0..3], "\xef\xbf\xbd");
                i += 3;
            } else i += 1;
        }
        break :blk normalized;
    };
    var session: parse.ParseSession = undefined;
    try session.init(allocator, parser_source, true);
    defer session.deinit();
    var converter: Converter = .{
        .allocator = allocator,
        .source = source,
        .session = &session,
        .p = try print.Printer.init(allocator, source),
        .analysis = .{ .allocator = allocator, .source = source, .tree = &session.tree, .embedded = &session.document.embedded },
    };
    for (session.document.diagnostics.items, session.document.diagnostic_origins.items) |diagnostic, origin| {
        if (origin == .javascript and copiedMarkupDiagnostic(&session, diagnostic)) continue;
        if (origin == .javascript and incompleteUnaryDiagnostic(&session, diagnostic)) continue;
        const start = diagnostic.start orelse 0;
        const end = diagnostic.end orelse 0;
        var script = false;
        for (session.document.nodes.items) |node| if (origin == .javascript and text.eql(node.type_name, "Script") and start >= (node.value_start orelse 0) and end <= (node.value_end orelse 0)) {
            script = true;
            break;
        };
        if (!script) {
            if (origin == .javascript and converter.analysis.skipEditorDiagnostic(.{ .start = start, .end = end })) continue;
            try converter.diagnostics.append(allocator, .{ .message = diagnostic.message, .severity = if (text.eql(diagnostic.severity, "warning")) 2 else if (text.eql(diagnostic.severity, "info")) 3 else if (text.eql(diagnostic.severity, "hint")) 4 else 1, .position = converter.p.range(start, end) });
        }
    }
    return converter.convert(options);
}

fn incompleteUnaryDiagnostic(session: *const parse.ParseSession, diagnostic: ast.AstroDiagnostic) bool {
    const start = diagnostic.start orelse return false;
    const end = diagnostic.end orelse return false;
    if (session.document.frontmatter) |frontmatter| {
        if (frontmatter.end < session.document.source.len and start >= frontmatter.start and end <= frontmatter.end and singleUnaryToken(session, frontmatter.start, frontmatter.end)) return true;
    }
    for (session.document.nodes.items, session.document.javascript_roots.items) |node, root| {
        if (!text.eql(node.type_name, "Expression") or root != std.math.maxInt(u32) or node.value_start == null or node.value_end == null) continue;
        if (start < node.value_start.? or end > node.value_end.?) continue;
        if (singleUnaryToken(session, node.value_start.?, node.value_end.?)) return true;
    }
    return false;
}

fn singleUnaryToken(session: *const parse.ParseSession, start: u32, end: u32) bool {
    var count: usize = 0;
    var unary = false;
    for (session.tree.tokens) |token| {
        if (token.tag == .eof or token.span.start < start or token.span.end > end) continue;
        count += 1;
        unary = switch (token.tag) {
            .logical_not, .plus, .minus, .bitwise_not, .typeof, .void, .delete => true,
            else => false,
        };
    }
    return count == 1 and unary;
}

fn copiedMarkupDiagnostic(session: *const parse.ParseSession, diagnostic: ast.AstroDiagnostic) bool {
    const start = diagnostic.start orelse 0;
    const end = diagnostic.end orelse 0;
    const nodes = session.document.nodes.items;
    for (nodes) |node| {
        if (!text.in(node.type_name, &.{ "Element", "Component", "Fragment", "Script", "Style" }) or start < node.start.? or end > node.end.?) continue;
        const malformed = node.opening_end == null or for (node.children) |id| {
            if (text.eql(nodes[id].type_name, "ClosingTag")) break true;
        } else false;
        if (!malformed) continue;
        const embedded = for (nodes) |parent| {
            if (text.eql(parent.type_name, "Expression") and parent.start.? < node.start.? and parent.end.? >= node.end.?) break true;
        } else false;
        if (!embedded) return true;
    }
    return false;
}

const Converter = struct {
    allocator: Allocator,
    source: []const u8,
    session: *parse.ParseSession,
    p: print.Printer,
    analysis: analysis_module.Analysis,
    diagnostics: std.ArrayList(print.Diagnostic) = .empty,
    expressions_disabled: bool = false,

    fn get(self: *const Converter, id: u32) ast.AstroNode {
        return self.session.document.nodes.items[id];
    }
    fn root(self: *const Converter, id: u32) ?u32 {
        return self.session.document.javascript_roots.items[id];
    }
    fn hasErrors(self: *const Converter, start: usize, end: usize) bool {
        const range = self.p.range(start, end);
        // Script bodies have already been excluded from TSX diagnostics.
        // Their JS errors must not force the surrounding expression to be copied.
        for (self.diagnostics.items) |item| if (item.position.start >= range.start and item.position.start <= range.end and item.severity == 1) return true;
        return false;
    }
    fn expression(self: *Converter, start: u32, end: u32, root_id: ?u32, require_value: bool) Error!void {
        const has_tokens = if (require_value and root_id == std.math.maxInt(u32) and !self.hasErrors(start, end)) for (self.session.tree.tokens) |token| {
            if (token.tag != .eof and token.span.start >= start and token.span.end <= end) break true;
        } else false else true;
        if (require_value and (text.trim(self.source[start..end]).len == 0 or !has_tokens)) {
            try self.p.put("(void 0)");
            if (root_id != null) for (self.session.tree.comments) |item| if (item.span.start >= start and item.span.start <= end) {
                try self.p.copy(start, end);
                break;
            };
            return;
        }
        if (root_id != null and self.hasErrors(start, end)) {
            try self.p.copy(start, end);
            return;
        }
        try self.emitEdits(start, end, try self.analysis.edits(root_id, null));
    }
    fn emitEdits(self: *Converter, start: u32, end: u32, edits: []const analysis_module.Edit) Error!void {
        var cursor = start;
        for (edits) |edit| {
            if (edit.start < cursor or edit.start < start or edit.end > end) continue;
            var leading = edit.start;
            if (edit.native) |id| if (self.get(id).implicit_fragment) {
                var trivia = leading;
                while (trivia > cursor) {
                    var prev = trivia - 1;
                    while (prev > cursor and self.source[prev] & 0xc0 == 0x80) prev -= 1;
                    if (!text.whitespace(text.cpAt(self.source, prev))) break;
                    trivia = prev;
                }
                var i: usize = trivia;
                while (i < leading) {
                    const cp = text.cpAt(self.source, i);
                    if (cp == '\r' or cp == '\n' or cp == 0x2028 or cp == 0x2029) {
                        leading = @intCast(i);
                        break;
                    }
                    i += text.cpLen(self.source, i);
                }
            };
            try self.p.copy(cursor, leading);
            if (edit.native) |id| try self.nativeExpression(id, 0, leading) else for (edit.pieces) |piece| {
                if (piece.text) |value| try self.p.put(value) else try self.p.copy(piece.start, piece.end);
            }
            cursor = edit.end;
        }
        try self.p.copy(cursor, end);
    }
    fn comment(self: *Converter, start: u32, end: u32, expression_context: bool) Error!void {
        const closed = end - start >= 7 and text.eql(self.source[end - 3 .. end], "-->");
        const body_start = @min(start + 4, end);
        const body_end = if (closed) end - 3 else end;
        try self.p.put(if (expression_context) "/**" else "{/**");
        if (body_start == end or !text.whitespace(text.cpAt(self.source, body_start))) try self.p.put(" ");
        try self.p.text(body_start, body_end, .comment);
        try self.p.put(if (expression_context) "*/" else "*/}");
        if (!closed) try self.diagnostics.append(self.allocator, .{ .message = "Unterminated comment", .severity = 2, .position = self.p.range(start, end) });
    }
    fn gaps(self: *Converter, start: u32, end: u32) Error!void {
        if (start >= end) return;
        var cursor = start;
        while (std.mem.indexOf(u8, self.source[cursor..end], "<!--")) |relative| {
            const begin = cursor + @as(u32, @intCast(relative));
            const close = if (std.mem.indexOf(u8, self.source[begin + 4 .. end], "-->")) |n| begin + 4 + @as(u32, @intCast(n)) + 3 else end;
            try self.p.copy(cursor, begin);
            try self.comment(begin, close, false);
            cursor = close;
        }
        try self.p.copy(cursor, end);
    }
    fn meaningfulChildren(self: *const Converter, children: []const u32) usize {
        var count: usize = 0;
        for (children) |id| {
            const n = self.get(id);
            if (!text.in(n.type_name, &.{ "Comment", "JsComment" }) and (!text.eql(n.type_name, "Text") or text.trim(n.text).len > 0)) count += 1;
        }
        return count;
    }
    fn nativeExpression(self: *Converter, id: u32, depth: u32, leading: ?u32) Error!void {
        const n = self.get(id);
        if (text.eql(n.type_name, "JsComment")) {
            try self.p.copy(n.start.?, n.end.?);
            return;
        }
        if (text.eql(n.type_name, "Comment")) {
            try self.comment(n.start.?, n.end.?, true);
            return;
        }
        if (text.eql(n.type_name, "Text") and text.trim(n.text).len == 0) {
            try self.p.copy(n.start.?, n.end.?);
            return;
        }
        if (n.implicit_fragment) {
            const group = self.meaningfulChildren(n.children) > 1;
            if (group) try self.p.put("<Fragment>");
            try self.p.copy(leading orelse n.start.?, n.start.?);
            for (n.children) |child| {
                if (group) try self.node(child, true, depth + 1) else try self.nativeExpression(child, depth + 1, null);
            }
            if (group) try self.p.put("</Fragment>");
            return;
        }
        try self.node(id, true, depth);
    }
    fn tagName(self: *Converter, name: []const u8, start: u32) Error!void {
        if (std.mem.indexOfAny(u8, name, " \t\r\n") == null) {
            try self.p.write(name, start);
            return;
        }
        var normalized: std.ArrayList(u8) = .empty;
        try normalized.ensureTotalCapacity(self.allocator, name.len);
        for (name) |character| if (!std.ascii.isWhitespace(character)) try normalized.append(self.allocator, character);
        try self.p.write(normalized.items, start);
    }
    fn attributeValueStart(self: *const Converter, start: u32, end: u32, embedded: bool) u32 {
        var cursor = start;
        while (cursor < end) {
            const cp = text.cpAt(self.source, cursor);
            if (text.whitespace(cp)) {
                if (embedded and (cp == '\r' or cp == '\n' or cp == 0x2028 or cp == 0x2029)) break;
                cursor += @intCast(text.cpLen(self.source, cursor));
            } else if (embedded and std.mem.startsWith(u8, self.source[cursor..end], "/*")) {
                const close = std.mem.indexOf(u8, self.source[cursor + 2 .. end], "*/") orelse break;
                cursor += @as(u32, @intCast(close)) + 4;
            } else if (embedded and std.mem.startsWith(u8, self.source[cursor..end], "//")) {
                cursor += 2;
                while (cursor < end) {
                    const next = text.cpAt(self.source, cursor);
                    if (next == '\r' or next == '\n' or next == 0x2028 or next == 0x2029) break;
                    cursor += @intCast(text.cpLen(self.source, cursor));
                }
            } else break;
        }
        return cursor;
    }
    fn attribute(self: *Converter, a: ast.AstroAttribute, embedded: bool, trailing: u32) Error!void {
        const p = &self.p;
        if (text.eql(a.kind, "spread")) {
            if (embedded) {
                try p.copy(a.start, a.value_start.?);
                try self.expression(a.value_start.?, a.value_end.?, if (a.expression) |id| self.root(id) else null, true);
                try p.copy(a.value_end.?, trailing);
            } else {
                try p.put(" {...");
                try self.expression(a.value_start.?, a.value_end.?, if (a.expression) |id| self.root(id) else null, true);
                try p.put("}");
            }
            return;
        }
        if (text.eql(a.kind, "comment")) {
            try p.put(" ");
            try p.copy(a.name_start.?, a.name_end.?);
            return;
        }
        if (text.eql(a.kind, "shorthand")) {
            const name_start = if (embedded) a.name_start.? else self.attributeValueStart(a.name_start.?, a.name_end.?, false);
            if (name_start == a.name_end.?) return;
            if (!embedded) try p.put(" ");
            try p.copy(name_start, a.name_end.?);
            const name = self.source[name_start..a.name_end.?];
            if (!embedded and std.mem.startsWith(u8, name, "/*") and std.mem.endsWith(u8, name, "*/")) return;
            try p.put("={");
            try p.copy(name_start, a.name_end.?);
            try p.put("}");
            return;
        }
        const key = a.name orelse return;
        if (key.len == 0) return;
        const dynamic = text.in(a.kind, &.{ "expression", "template" });
        const valid_name = text.jsxName(key);
        if (!embedded or !valid_name) try p.put(" ");
        if (!valid_name) {
            try p.put("{...{");
            try p.quoted(a.name_start.?, a.name_end.?);
            try p.put(":");
            if (dynamic) {
                if (text.eql(a.kind, "expression")) {
                    // Object property values must keep comma expressions as one value.
                    try p.put("(");
                    const value_start = self.attributeValueStart(a.value_start.?, a.value_end.?, embedded);
                    if (value_start == a.value_end.?) try p.put("void 0") else try self.expression(value_start, a.value_end.?, if (a.expression) |id| self.root(id) else null, true);
                    try p.put(")");
                } else try self.expression(a.value_start.?, a.value_end.?, if (a.expression) |id| self.root(id) else null, true);
            } else if (text.eql(a.kind, "boolean")) try p.put("true") else try p.stringValue(try text.decodeEntities(self.allocator, a.value orelse ""));
            try p.put("}}");
            return;
        }
        try p.copy(a.name_start.?, a.name_end.?);
        if (text.eql(a.kind, "boolean")) {
            if (embedded) try p.copy(a.name_end.?, trailing);
            return;
        }
        const eq = a.name_end.? + @as(u32, @intCast(std.mem.indexOfScalar(u8, self.source[a.name_end.?..], '=') orelse 0));
        try p.copy(if (embedded) a.name_end.? else eq, eq + 1);
        if (embedded) try p.copy(eq + 1, a.literal_start orelse a.value_start.?);
        if (dynamic) {
            if (embedded and text.eql(a.kind, "expression")) {
                try p.copy(a.literal_start orelse a.value_start.? - 1, a.value_start.?);
                try self.expression(a.value_start.?, a.value_end.?, if (a.expression) |id| self.root(id) else null, true);
                try p.copy(a.value_end.?, trailing);
                return;
            }
            try p.put("{");
            try self.expression(a.value_start.?, a.value_end.?, if (a.expression) |id| self.root(id) else null, true);
            if (embedded and text.eql(a.kind, "template")) try p.copy(a.end, trailing);
            try p.put("}");
            if (embedded and text.eql(a.kind, "template")) return;
        } else {
            const value_start = p.length + 1;
            if (text.eql(a.kind, "quoted")) try p.copy(a.literal_start.?, a.literal_end.?) else {
                try p.put("\"");
                try p.text(a.value_start.?, a.value_end.?, .attribute);
                try p.put("\"");
            }
            const lower = try text.lower(self.allocator, key);
            const generated: Range = .{ .start = value_start, .end = p.length - 1 };
            if (data.events.has(lower)) {
                try p.scripts.append(self.allocator, .{ .position = p.range(a.value_start.?, a.value_end.?), .content = a.value orelse "", .type = "event-attribute" });
                try p.script_ranges.append(self.allocator, generated);
            }
            if (text.eql(lower, "style")) {
                try p.styles.append(self.allocator, .{ .position = p.range(a.value_start.?, a.value_end.?), .content = a.value orelse "", .type = "style-attribute", .lang = "css" });
                try p.style_ranges.append(self.allocator, generated);
            }
        }
        if (embedded) try p.copy(a.end, trailing);
    }
    const AttrValue = struct { found: bool = false, dynamic: bool = false, value: []const u8 = "" };
    fn attrValue(self: *const Converter, n: ast.AstroNode, wanted: []const u8) Error!AttrValue {
        for (n.attributes) |a| if (a.name) |name| {
            if (!std.ascii.eqlIgnoreCase(name, wanted)) continue;
            if (text.eql(a.kind, "boolean")) return .{ .found = true };
            if (text.in(a.kind, &.{ "quoted", "unquoted" })) return .{ .found = true, .value = try text.decodeEntities(self.allocator, a.value orelse "") };
            return .{ .found = true, .dynamic = true };
        };
        return .{};
    }
    fn hasAttr(n: ast.AstroNode, name: []const u8) bool {
        for (n.attributes) |a| if (a.name) |key| if (text.eql(key, name)) return true;
        return false;
    }
    fn scriptType(self: *Converter, n: ast.AstroNode) Error![]const u8 {
        if (n.attributes.len == 0) return "processed-module";
        if (hasAttr(n, "is:raw")) return "raw";
        const kind = try self.attrValue(n, "type");
        if (kind.dynamic) return "unknown";
        if (!kind.found) return "inline";
        const value = try text.lower(self.allocator, text.trim(kind.value));
        if (text.eql(value, "module")) return "module";
        if (text.in(value, &.{ "", "text/javascript", "application/javascript", "application/ecmascript", "application/x-ecmascript", "application/x-javascript", "text/ecmascript", "text/javascript1.0", "text/javascript1.1", "text/javascript1.2", "text/javascript1.3", "text/javascript1.4", "text/javascript1.5", "text/jscript", "text/livescript", "text/x-ecmascript", "text/x-javascript", "text/partytown" })) return "inline";
        if (text.in(value, &.{ "application/json", "application/ld+json", "importmap", "speculationrules" })) return "json";
        return "unknown";
    }
    fn literalBody(self: *Converter, start: u32, end: u32, children: []const u32, depth: u32) Error!void {
        var expressions: std.ArrayList(ast.AstroNode) = .empty;
        var pending: std.ArrayList(u32) = .empty;
        try pending.appendSlice(self.allocator, children);
        while (pending.pop()) |id| {
            const n = self.get(id);
            if (text.eql(n.type_name, "Expression")) try expressions.append(self.allocator, n) else try pending.appendSlice(self.allocator, n.children);
        }
        std.mem.sort(ast.AstroNode, expressions.items, {}, struct {
            fn less(_: void, a: ast.AstroNode, b: ast.AstroNode) bool {
                return a.start.? < b.start.?;
            }
        }.less);
        var cursor = start;
        for (expressions.items) |n| {
            try self.p.text(cursor, n.start.?, .jsx);
            try self.node(n.id, false, depth + 1);
            cursor = n.end.?;
        }
        try self.p.text(cursor, end, .jsx);
    }
    // The embedded JSX lexer attaches comments touching `>` to that token.
    fn bodyTrivia(self: *Converter, start: u32, end: u32) Error!u32 {
        var cursor = start;
        while (std.mem.startsWith(u8, self.source[cursor..end], "<!--")) {
            const close = std.mem.indexOf(u8, self.source[cursor + 4 .. end], "-->") orelse break;
            const next = cursor + 4 + @as(u32, @intCast(close)) + 3;
            try self.comment(cursor, next, false);
            cursor = next;
        }
        return cursor;
    }
    fn node(self: *Converter, id: u32, embedded: bool, depth: u32) Error!void {
        const n = self.get(id);
        const p = &self.p;
        const start = n.start orelse 0;
        const end = n.end orelse start;
        if (depth > 128) {
            try p.copy(start, end);
            return;
        }
        if (text.eql(n.type_name, "Text")) {
            try p.text(start, end, .jsx);
            return;
        }
        if (text.eql(n.type_name, "ClosingTag")) {
            try p.copy(start, end);
            return;
        }
        if (text.eql(n.type_name, "JsComment")) {
            try p.put("{");
            try p.copy(start, end);
            if (std.mem.startsWith(u8, n.text, "//")) try p.put("\n");
            try p.put("}");
            return;
        }
        if (text.eql(n.type_name, "Doctype")) return;
        if (text.eql(n.type_name, "Declaration") and std.mem.startsWith(u8, self.source[start..end], "<?")) {
            try p.put("{/** ");
            try p.text(start, end, .comment);
            try p.put("*/}");
            return;
        }
        if (text.eql(n.type_name, "Comment")) {
            try self.comment(start, end, false);
            return;
        }
        if (text.eql(n.type_name, "Expression")) {
            if (embedded and self.expressions_disabled) {
                try p.text(start, end, .jsx);
                return;
            }
            if (self.hasErrors(start + 1, end)) {
                try p.copy(start, end);
                return;
            }
            if (!std.mem.endsWith(u8, self.source[start..end], "}")) {
                try p.copy(start, end);
                return;
            }
            if (text.trim(self.source[start + 1 .. end - 1]).len == 0) return;
            if (n.spread) try self.diagnostics.append(self.allocator, .{ .message = "Spread is not valid in a JSX child expression", .severity = 1, .position = p.range(start + 1, n.value_start.?) });
            try p.copy(start, start + 1);
            if (self.root(id) == null and n.children.len > 0) {
                for (n.children) |child| {
                    const value = self.get(child);
                    if (text.eql(value.type_name, "Text") and text.trim(value.text).len > 0) {
                        try p.copy(start + 1, end);
                        return;
                    }
                }
                const group = self.meaningfulChildren(n.children) > 1;
                if (group) try p.put("<Fragment>");
                try p.copy(start + 1, self.get(n.children[0]).start.?);
                for (n.children) |child| {
                    if (group) try self.node(child, true, depth + 1) else try self.nativeExpression(child, depth + 1, null);
                }
                if (group) try p.put("</Fragment>");
                try p.copy(self.get(n.children[n.children.len - 1]).end.?, end - 1);
            } else try self.expression(start + 1, end - 1, self.root(id), false);
            try p.copy(end - 1, end);
            return;
        }
        if (n.implicit_fragment) {
            try p.put("<Fragment>");
            for (n.children) |child| try self.node(child, true, depth + 1);
            try p.put("</Fragment>");
            return;
        }
        if (!text.in(n.type_name, &.{ "Element", "Component", "Fragment", "Script", "Style" })) {
            try self.gaps(start, end);
            return;
        }
        for (n.children) |child| if (text.eql(self.get(child).type_name, "ClosingTag")) {
            try p.copy(start, end);
            return;
        };
        const type_args = self.session.document.type_argument_roots.items[id];
        if (!embedded) if (type_args) |root_id| if (root_id != std.math.maxInt(u32)) {
            const span = self.session.tree.span(@fromBackingInt(@intCast(root_id)));
            try self.diagnostics.append(self.allocator, .{ .message = "Generic tags require an expression container in editor TSX", .severity = 1, .position = p.range(span.start, span.end) });
            try p.copy(start, end);
            return;
        };
        const opening_end = n.opening_end orelse {
            try p.copy(start, end);
            return;
        };
        if (opening_end == 0 or self.source[opening_end - 1] != '>') {
            try p.copy(start, end);
            return;
        }
        if (text.eql(n.type_name, "Fragment") and (n.name == null or n.name.?.len == 0)) try p.copy(start, opening_end) else {
            try p.copy(start, start + 1);
            if (embedded) try p.copy(start + 1, n.name_end.?) else try self.tagName(n.name.?, n.name_start.?);
            var name_end = n.name_end.?;
            if (type_args) |root_id| if (root_id != std.math.maxInt(u32)) {
                const span = self.session.tree.span(@fromBackingInt(@intCast(root_id)));
                name_end = if (n.attributes.len > 0) n.attributes[0].start else span.end;
            };
            const attrs_end = if (n.attributes.len > 0) n.attributes[n.attributes.len - 1].end else name_end;
            const gt = opening_end - 1;
            const slash = if (n.self_closing) gt - 1 else gt;
            if (embedded and n.attributes.len > 0) try p.copy(name_end, n.attributes[0].start);
            for (n.attributes, 0..) |a, i| try self.attribute(a, embedded, if (i + 1 < n.attributes.len) n.attributes[i + 1].start else slash);
            if (!embedded or n.attributes.len == 0) try p.copy(attrs_end, slash);
            if (n.self_closing) try p.copy(slash, gt) else if (n.implicit_void) try p.put("/");
            try p.copy(gt, gt + 1);
        }
        if (n.self_closing or n.implicit_void) return;
        const lower = if (text.eql(n.type_name, "Component")) "" else try text.lower(self.allocator, n.name orelse "");
        const body_end = n.closing_start orelse end;
        if (text.eql(lower, "script") or text.eql(lower, "style")) {
            const generated: Range = .{ .start = p.length, .end = p.length };
            if (text.eql(lower, "script")) {
                try p.scripts.append(self.allocator, .{ .position = p.range(opening_end, body_end), .content = self.source[opening_end..body_end], .type = try self.scriptType(n) });
                try p.script_ranges.append(self.allocator, generated);
            } else {
                const lang = try self.attrValue(n, "lang");
                try p.styles.append(self.allocator, .{ .position = p.range(opening_end, body_end), .content = self.source[opening_end..body_end], .type = "tag", .lang = if (lang.dynamic) "unknown" else try text.lower(self.allocator, text.trim(if (lang.found) lang.value else "css")) });
                try p.style_ranges.append(self.allocator, generated);
            }
        } else if (hasAttr(n, "is:raw") or text.in(lower, &.{ "iframe", "noembed", "noframes", "plaintext", "xmp" })) {
            if (embedded) _ = try self.bodyTrivia(opening_end, body_end);
            if (body_end > opening_end) {
                try p.put("{`");
                try p.text(opening_end, body_end, .template);
                try p.put("`}");
            }
        } else if (text.in(lower, &.{ "textarea", "title" })) {
            const content_start = if (embedded) try self.bodyTrivia(opening_end, body_end) else opening_end;
            try self.literalBody(content_start, body_end, n.children, depth);
        } else {
            const disabled = self.expressions_disabled;
            self.expressions_disabled = disabled or (embedded and text.eql(lower, "math"));
            defer self.expressions_disabled = disabled;
            var cursor = opening_end;
            for (n.children) |child| {
                const next = self.get(child);
                try self.gaps(cursor, next.start.?);
                try self.node(child, embedded, depth + 1);
                cursor = next.end.?;
            }
            try self.gaps(cursor, body_end);
        }
        if (n.closing_start) |closing_start| {
            try p.copy(closing_start, closing_start + 2);
            if (embedded) try p.copy(n.closing_name_start.?, n.closing_name_end.?) else try self.tagName(self.source[n.closing_name_start.?..n.closing_name_end.?], n.closing_name_start.?);
            if (n.closed) try p.copy(n.closing_end.? - 1, n.closing_end.?) else try p.copy(n.closing_name_end.?, n.closing_end.?);
        }
    }
    fn addExtra(self: *Converter, extra: *std.ArrayList([]const u32), values: []const u32) Error!void {
        try extra.append(self.allocator, try self.allocator.dupe(u32, values));
    }
    fn convert(self: *Converter, options: Options) Error!Result {
        const p = &self.p;
        const document = &self.session.document;
        const names = try text.componentNames(self.allocator, options.filename);
        const props = try self.analysis.analyze(document.frontmatter_root, names.alias);
        var extra: std.ArrayList([]const u32) = .empty;
        try p.put("/* @jsxImportSource astro */\n\n");
        var frontmatter: Range = .{ .start = p.length, .end = p.length };
        if (document.frontmatter == null) try self.addExtra(&extra, &.{ 29, 1, 0, 0, 1, 4 });
        var body_start: u32 = 0;
        var status: []const u8 = "doesnt-exist";
        var frontmatter_source: Range = .{ .start = 0, .end = 0 };
        var needs_terminator = false;
        var fence_end: u32 = 0;
        if (document.frontmatter) |fm| {
            const closed = std.mem.startsWith(u8, self.source[fm.end..], "---");
            status = if (closed) "closed" else "open";
            fence_end = if (closed) fm.end + 3 else fm.end;
            frontmatter_source = p.range(fm.start - 3, fence_end);
            body_start = fence_end;
            needs_terminator = text.trim(fm.source).len > 0;
            var content_start = fm.start;
            while (content_start < fm.end and (self.source[content_start] == ' ' or self.source[content_start] == '\t')) : (content_start += 1) {}
            if (needs_terminator) {
                var diagnostics: std.ArrayList(analysis_module.EditorDiagnostic) = .empty;
                try self.emitEdits(content_start, fm.end, try self.analysis.edits(document.frontmatter_root, &diagnostics));
                for (diagnostics.items) |diagnostic|
                    try self.diagnostics.append(self.allocator, .{ .message = diagnostic.message, .severity = 1, .position = p.range(diagnostic.span.start, diagnostic.span.end) });
            }
            if (!needs_terminator and std.mem.startsWith(u8, self.source[fm.start..], "\r\n")) try p.copy(fm.start, fm.start + 2) else try p.write("\n", if (!needs_terminator and fm.start < self.source.len and self.source[fm.start] == '\n') fm.start else null);
            frontmatter.end = p.length;
        }
        var meaningful = false;
        var scan = body_start;
        for (document.roots.items) |id| {
            const n = self.get(id);
            if (text.eql(n.type_name, "Doctype") and n.start.? >= scan) {
                meaningful = meaningful or text.trim(self.source[scan..n.start.?]).len > 0;
                scan = n.end.?;
            }
        }
        meaningful = meaningful or text.trim(self.source[scan..]).len > 0;
        var body: Range = undefined;
        if (meaningful) {
            if (document.frontmatter != null and needs_terminator) try p.put(";{};");
            try p.put("<Fragment>\n");
            body = .{ .start = p.length, .end = p.length };
            if (document.frontmatter != null and needs_terminator and text.eql(status, "closed")) try self.addExtra(&extra, &.{ frontmatter.end, body.start - frontmatter.end, p.position(fence_end - 3), 0, 1 });
            var cursor = body_start;
            for (document.roots.items) |id| {
                const n = self.get(id);
                if (n.start.? < cursor) continue;
                try self.gaps(cursor, n.start.?);
                try self.node(id, false, 0);
                cursor = n.end.?;
            }
            try self.gaps(cursor, @intCast(self.source.len));
            try p.write("\n", self.source.len);
            body.end = p.length;
            try p.put("</Fragment>\n");
        } else {
            if (document.frontmatter != null) try p.put("\n");
            body = .{ .start = p.length, .end = p.length };
        }
        try p.put("export default function ");
        const component_range: Range = .{ .start = p.length, .end = p.length + print.utf16Length(names.component) };
        try p.put(names.component);
        const inferred = "ASTRO__MergeUnion<ASTRO__Get<ASTRO__InferredGetStaticPath, 'props'>>";
        const props_type = if (props.props) try std.fmt.allocPrint(self.allocator, "Props{s}", .{props.args}) else if (props.get_static_paths) inferred else "Record<string, any>";
        const global_props = if (props.props and props.args.len > 0) try std.fmt.allocPrint(self.allocator, "Parameters<typeof {s}>[0]", .{names.component}) else props_type;
        if (props.props) try p.put(props.generic);
        try p.put("(_props: ");
        try p.put(props_type);
        try p.put("): any {}\n");
        if (props.get_static_paths) try p.put(data.inferred_types);
        if (options.ambient_types) try p.put("declare const Fragment: any;\n");
        if (props.props or props.get_static_paths or options.ambient_types) {
            try p.put(data.astro_comment);
            try p.put("declare const Astro: Readonly<import('astro').AstroGlobal<");
            try p.put(global_props);
            try p.put(", typeof ");
            try p.put(names.component);
            if (props.get_static_paths) try p.put(", ASTRO__Get<ASTRO__InferredGetStaticPath, 'params'>");
            try p.put(">>;\n");
        }
        var generated_export: ?Range = null;
        if (names.alias) |alias| if (!props.exported) {
            try p.put("\n");
            const begin = p.length;
            try p.put("export { ");
            try p.put(names.component);
            try p.put(" as ");
            try p.put(alias);
            try p.put(" };\n");
            generated_export = .{ .start = begin, .end = p.length };
        };
        try self.addExtra(&extra, &.{ component_range.start, component_range.end - component_range.start, 0, 0, 1, 72 });
        std.mem.sort(print.Diagnostic, self.diagnostics.items, {}, struct {
            fn less(_: void, a: print.Diagnostic, b: print.Diagnostic) bool {
                return a.position.start < b.position.start or (a.position.start == b.position.start and a.position.end < b.position.end);
            }
        }.less);
        var errors = false;
        for (self.diagnostics.items) |diagnostic| if (diagnostic.severity == 1) {
            errors = true;
            break;
        };
        return .{ .code = p.code.items, .mappings = try p.mappings(extra.items), .frontmatter = frontmatter, .body = body, .frontmatter_status = status, .frontmatter_source = frontmatter_source, .scripts = p.scripts.items, .styles = p.styles.items, .generated_script_ranges = p.script_ranges.items, .generated_style_ranges = p.style_ranges.items, .diagnostics = self.diagnostics.items, .has_parse_errors = errors, .generated_component_export = generated_export };
    }
};
