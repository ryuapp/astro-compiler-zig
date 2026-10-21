const std = @import("std");
const yuku = @import("parser");
const native = @import("native_parser.zig");
const Session = @import("astro_parse.zig").ParseSession;
const Index = yuku.ast.NodeIndex;
const Error = error{OutOfMemory};

pub const Pending = struct {
    document: *native.Document,
    id: u32,
    roots: yuku.ast.IndexRange = .empty,
    diagnostics: yuku.ast.IndexRange = .empty,
    javascript_diagnostics: yuku.ast.IndexRange = .empty,
    comments: yuku.ast.IndexRange = .empty,
    fatal: bool = false,
};

pub fn endExpression(parser: *yuku.dialect.Parser, left: Index) Error!yuku.dialect.Claim {
    const token = parser.token();
    if (token.tag != .less_than) return .decline;
    const source = parser.source();
    if (!std.mem.startsWith(u8, source[token.span.start..parser.range().end], "</")) {
        return .decline;
    }
    const session: *Session = @alignCast(@fieldParentPtr("tree", parser.tree()));
    const end = parser.tree().span(left).end;
    std.debug.assert(end <= token.span.start);
    if (std.mem.trim(u8, source[end..token.span.start], " \t\r\n").len > 0) return .decline;
    // a closing tag terminates a markup operand before JS reads a regexp
    var candidates = session.pending.keyIterator();
    while (candidates.next()) |index| {
        if (@backingInt(index.*) >= parser.tree().nodes.len) continue;
        if (parser.tree().data(index.*) != .dialect) continue;
        if (parser.tree().span(index.*).end == end) return .end;
    }
    return .decline;
}

pub fn expression(parser: *yuku.dialect.Parser) Error!yuku.dialect.Claim {
    if (parser.token().tag != .less_than) return .decline;
    switch (parser.parseOptions().lang) {
        .js, .ts, .dts => return .decline,
        .jsx, .tsx => {},
    }
    if (genericArrow(parser)) return .decline;
    const session: *Session = @alignCast(@fieldParentPtr("tree", parser.tree()));
    std.debug.assert(session.document.source.ptr == parser.source().ptr);
    std.debug.assert(session.candidate_depth <= session.candidates.items.len);
    const parent = session.active_document;
    if (parent.standard_frontmatter_jsx and std.mem.eql(u8, parent.region, "frontmatter")) {
        return .decline;
    }
    const begin = parser.token().span.start;
    if (!parent.isMarkup(begin) and !(parent.editor_mode and begin < parser.range().end)) {
        return .decline;
    }
    // speculative markup owns only temporary host views and appends to the shared tree
    if (session.candidate_depth == 256) {
        try parser.report(parser.token().span, "Markup nesting exceeds parser limit");
        return .failed;
    }
    if (session.candidate_depth == session.candidates.items.len) {
        const candidate = try parent.allocator.create(native.Document);
        candidate.init(parent.allocator, parent.source);
        try session.candidates.append(parent.allocator, candidate);
    }
    const document = session.candidates.items[session.candidate_depth];
    session.candidate_depth += 1;
    defer session.candidate_depth -= 1;
    // candidate records are append-only so old metadata survives tree speculation
    document.embedded.clearRetainingCapacity();
    document.stack.clearRetainingCapacity();
    document.active_children = null;
    document.handled_diagnostics.clearRetainingCapacity();
    document.fatal_markup = false;
    document.halt_body = false;
    document.fatal_root = null;
    const roots_start: u32 = @intCast(document.embedded_roots.items.len);
    const diagnostics_start: u32 = @intCast(document.diagnostics.items.len);
    const comments_start: u32 = @intCast(document.js_comments.items.len);
    document.session = session;
    document.expression_parser = parser;
    defer document.expression_parser = null;
    document.body_parser = parent.body_parser;
    document.cursor = begin;
    document.limit = parser.range().end;
    document.region = parent.region;
    document.depth = parent.depth;
    document.attribute_void = parent.attribute_void;
    document.editor_mode = parent.editor_mode;
    document.preserve_script_trivia = parent.preserve_script_trivia;
    document.standard_frontmatter_jsx = parent.standard_frontmatter_jsx;
    document.collect_tokens = parent.collect_tokens;
    const javascript_diagnostics_start: u32 = @intCast(session.body_parser.diagnostics.items.len);
    document.reported_diagnostics = javascript_diagnostics_start;
    session.active_document = document;
    defer session.active_document = parent;
    var children: std.ArrayList(u32) = .empty;
    try children.append(parent.allocator, try document.markup(.{
        .jsx = true,
    }));
    while (!(document.standard_frontmatter_jsx and
        std.mem.eql(u8, document.region, "frontmatter")))
    {
        const previous = document.cursor;
        while (document.cursor < document.limit and
            std.ascii.isWhitespace(document.source[document.cursor])) : (document.cursor += 1)
        {}
        if (!document.isMarkup(document.cursor) or
            std.mem.startsWith(u8, document.source[document.cursor..document.limit], "</"))
        {
            document.cursor = previous;
            break;
        }
        if (document.cursor > previous) {
            const text = try document.addNode("Text", previous, document.cursor);
            document.nodes.items[text].value = document.source[previous..document.cursor];
            try children.append(parent.allocator, text);
        }
        try children.append(parent.allocator, try document.markup(.{
            .jsx = true,
        }));
    }
    const id = if (children.items.len == 1) children.items[0] else block: {
        const fragment = try document.addNode("Fragment", begin, document.cursor);
        document.nodes.items[fragment].children = children.items;
        document.nodes.items[fragment].implicit_fragment = true;
        break :block fragment;
    };
    const root = try buildNode(document, id, 0);
    try session.pending.put(document.allocator, root, .{
        .document = document,
        .id = id,
        .roots = .{
            .start = roots_start,
            .len = @as(u32, @intCast(document.embedded_roots.items.len)) - roots_start,
        },
        .diagnostics = .{
            .start = diagnostics_start,
            .len = @as(u32, @intCast(document.diagnostics.items.len)) - diagnostics_start,
        },
        .javascript_diagnostics = .{
            .start = javascript_diagnostics_start,
            .len = @as(u32, @intCast(session.body_parser.diagnostics.items.len)) - javascript_diagnostics_start,
        },
        .comments = .{
            .start = comments_start,
            .len = @as(u32, @intCast(document.js_comments.items.len)) - comments_start,
        },
        .fatal = document.fatal_markup,
    });
    session.pending_epoch += 1;
    if (!try parser.seek(@intCast(document.cursor))) return .failed;
    return .{ .node = root };
}

// use token lookahead only so a standard generic arrow is parsed once by Yuku
fn genericArrow(parser: *yuku.dialect.Parser) bool {
    std.debug.assert(parser.token().tag == .less_than);
    std.debug.assert(parser.range().end <= parser.source().len);
    const end = angleEnd(parser, parser.token().span.start, parser.range().end) orelse
        return false;
    var token = parser.tokenAt(end);
    if (token.tag != .left_paren) return false;
    var depth: u32 = 0;
    var cursor = end;
    for (0..parser.source().len + 1) |_| {
        token = parser.tokenAt(cursor);
        if (token.span.end <= cursor) return false;
        cursor = token.span.end;
        switch (token.tag) {
            .left_paren => depth += 1,
            .right_paren => {
                if (depth == 0) return false;
                depth -= 1;
                if (depth == 0) {
                    const following = parser.tokenAt(cursor);
                    if (following.tag == .arrow) return true;
                    if (following.tag != .colon) return false;
                    cursor = following.span.end;
                    for (0..parser.range().end - cursor + 1) |_| {
                        const annotation = parser.tokenAt(cursor);
                        if (annotation.tag == .arrow) return true;
                        if (annotation.span.end <= cursor or annotation.tag == .eof) return false;
                        if (annotation.tag == .less_than and
                            annotation.span.end < parser.range().end)
                        {
                            if (parser.source()[annotation.span.end] == '/') return false;
                        }
                        cursor = annotation.span.end;
                    } else unreachable;
                }
            },
            .eof => return false,
            else => {},
        }
    } else unreachable;
}

pub fn angleEnd(parser: *yuku.dialect.Parser, start: u32, end: u32) ?u32 {
    const source = parser.source();
    std.debug.assert(start <= end);
    std.debug.assert(end <= source.len);
    var offset = start;
    var depth: u32 = 0;
    for (0..end - start + 1) |_| {
        const token = parser.tokenAt(offset);
        if (token.span.end <= offset) return null;
        offset = token.span.end;
        if (token.tag == .less_than) {
            depth += 1;
        } else {
            if (token.tag == .eof) return null;
            var cursor = token.span.start;
            while (cursor < token.span.end and source[cursor] == '>') : (cursor += 1) {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return cursor + 1;
            }
        }
    } else unreachable;
}

pub fn connect(document: *native.Document, root: Index, pending_epoch: u64) Error!void {
    const session = document.session;
    std.debug.assert(document.source.ptr == session.tree.source.ptr);
    if (session.pending_epoch == pending_epoch or root == .null) return;
    const tree = &session.tree;
    session.connect_stack.clearRetainingCapacity();
    session.connect_seen.clearRetainingCapacity();
    try session.connect_stack.append(document.allocator, root);
    while (session.connect_stack.pop()) |index| {
        if (index == .null) continue;
        const seen = try session.connect_seen.getOrPut(document.allocator, index);
        if (seen.found_existing) continue;
        std.debug.assert(session.connect_seen.count() <= tree.nodes.len);
        const data = tree.data(index);
        if (data == .dialect) {
            const pending = session.pending.get(index).?;
            const imported = document.embedded.contains(index);
            const id = try importNode(document, &pending, 0);
            if (!imported) {
                const origin = pending.document;
                const diagnostics = pending.diagnostics;
                for (
                    origin.diagnostics.items[diagnostics.start..][0..diagnostics.len],
                    origin.diagnostic_origins.items[diagnostics.start..][0..diagnostics.len],
                ) |diagnostic, kind| {
                    try document.diagnostics.append(document.allocator, diagnostic);
                    try document.diagnostic_origins.append(document.allocator, kind);
                }
                // committed markup already selected and positioned its embedded diagnostics
                if (pending.javascript_diagnostics.len > 0)
                    try document.handled_diagnostics.append(document.allocator, pending.javascript_diagnostics);
                try document.js_comments.appendSlice(
                    document.allocator,
                    origin.js_comments.items[pending.comments.start..][0..pending.comments.len],
                );
                try document.embedded_roots.appendSlice(
                    document.allocator,
                    origin.embedded_roots.items[pending.roots.start..][0..pending.roots.len],
                );
                try document.embedded_roots.append(document.allocator, index);
                if (pending.fatal) {
                    if (document.editor_mode) {
                        document.fatal_markup = true;
                    } else {
                        document.halt_body = true;
                    }
                }
            }
            if (document.active_children) |children| {
                if (std.mem.findScalar(u32, children.items, id) == null) {
                    try children.append(document.allocator, id);
                }
            }
            continue;
        }
        switch (data) {
            inline else => |payload| {
                if (@typeInfo(@TypeOf(payload)) == .@"struct") {
                    const fields = @import("meta").fields(@TypeOf(payload));
                    inline for (0..fields.len) |field_index| {
                        const field = fields[fields.len - 1 - field_index];
                        if (field.type == Index) {
                            try session.connect_stack.append(
                                document.allocator,
                                @field(payload, field.name),
                            );
                        } else if (field.type == yuku.ast.IndexRange) {
                            const children = tree.extra(@field(payload, field.name));
                            var position = children.len;
                            while (position > 0) {
                                position -= 1;
                                try session.connect_stack.append(
                                    document.allocator,
                                    children[position],
                                );
                            }
                        }
                    }
                }
            },
        }
    }
}

fn importNode(target: *native.Document, pending: *const Pending, depth: u32) Error!u32 {
    std.debug.assert(depth < 1024);
    const source = pending.document;
    std.debug.assert(source.session == target.session);
    std.debug.assert(pending.id < source.nodes.items.len);
    const index = source.tree_nodes.items[pending.id];
    std.debug.assert(index != .null);
    if (source == target) return pending.id;
    if (target.embedded.get(index)) |id| return id;
    const node = source.nodes.items[pending.id];
    const id = try target.addNode(node.type_name, node.start orelse 0, node.end orelse 0);
    try target.embedded.put(target.allocator, index, id);
    target.tree_nodes.items[id] = index;
    target.javascript_roots.items[id] = source.javascript_roots.items[pending.id];
    target.type_argument_roots.items[id] = source.type_argument_roots.items[pending.id];
    var copied = node;
    copied.id = id;
    const children = try target.allocator.alloc(u32, node.children.len);
    for (node.children, children) |child, *replacement| {
        replacement.* = try importNode(target, &.{ .document = source, .id = child }, depth + 1);
    }
    copied.children = children;
    const attributes = try target.allocator.dupe(
        @import("astro_types.zig").AstroAttribute,
        node.attributes,
    );
    for (attributes) |*attribute| {
        if (attribute.expression) |expression_id| {
            attribute.expression = try importNode(target, &.{
                .document = source,
                .id = expression_id,
            }, depth + 1);
        }
    }
    copied.attributes = attributes;
    target.nodes.items[id] = copied;
    return id;
}

pub fn documentRoot(session: *Session) Error!Index {
    var children: std.ArrayList(Index) = .empty;
    const document = &session.document;
    std.debug.assert(session.tree.root == .null);
    std.debug.assert(document.body_parser.tree == &session.tree);
    if (document.frontmatter_root) |root| {
        const program = session.tree.data(@fromBackingInt(root)).program;
        try children.appendSlice(document.allocator, session.tree.extra(program.body));
    }
    for (document.roots.items) |id| {
        try children.append(document.allocator, try buildNode(document, id, 0));
    }
    const document_root = try session.tree.addNode(.{ .dialect = .{
        .kind = .document,
        .children = try session.tree.addExtra(children.items),
    } }, .{ .start = 0, .end = @intCast(document.source.len) });
    return session.tree.addNode(.{ .program = .{
        .source_type = .module,
        .body = try session.tree.addExtra(&.{document_root}),
        .hashbang = null,
    } }, .{ .start = 0, .end = @intCast(document.source.len) });
}

fn buildNode(document: *native.Document, id: u32, depth: u32) Error!Index {
    std.debug.assert(depth < 1024);
    std.debug.assert(id < document.nodes.items.len);
    if (document.tree_nodes.items[id] != .null) return document.tree_nodes.items[id];
    const node = document.nodes.items[id];
    const tree = &document.session.tree;
    var children: std.ArrayList(Index) = .empty;
    if (document.javascript_roots.items[id]) |root| {
        if (root != std.math.maxInt(u32)) {
            try children.append(document.allocator, @fromBackingInt(root));
        }
    }
    if (node.name) |name| {
        if (name.len > 0 and node.name_start != null and node.opening_end != null) {
            const start = node.name_start.?;
            var name_index: Index = .null;
            var parts = std.mem.tokenizeAny(u8, name, ". \t\r\n");
            while (parts.next()) |part| {
                const position = start + @as(u32, @intCast(
                    @intFromPtr(part.ptr) - @intFromPtr(name.ptr),
                ));
                const end = position + @as(u32, @intCast(part.len));
                const identifier = try tree.addNode(.{ .jsx_identifier = .{
                    .name = tree.sourceSlice(position, end),
                } }, .{ .start = position, .end = end });
                name_index = if (name_index == .null) identifier else try tree.addNode(.{
                    .jsx_member_expression = .{ .object = name_index, .property = identifier },
                }, .{ .start = start, .end = end });
            }
            const type_arguments: Index = if (document.type_argument_roots.items[id]) |root|
                @fromBackingInt(root)
            else
                .null;
            const opening = try tree.addNode(.{ .jsx_opening_element = .{
                .name = name_index,
                .type_arguments = type_arguments,
                .attributes = .empty,
                .self_closing = node.self_closing or node.implicit_void,
            } }, .{ .start = node.start orelse 0, .end = node.opening_end.? });
            try children.append(document.allocator, opening);
        }
    }
    for (node.attributes) |attribute| {
        if (attribute.expression) |expression_id| {
            try children.append(
                document.allocator,
                try buildNode(document, expression_id, depth + 1),
            );
        }
    }
    if (!std.mem.eql(u8, node.type_name, "Expression")) {
        for (node.children) |child| {
            try children.append(document.allocator, try buildNode(document, child, depth + 1));
        }
    }
    const kinds = std.StaticStringMap(yuku.dialect.Kind).initComptime(.{
        .{ "Element", .element },        .{ "Component", .component },   .{ "Fragment", .fragment },
        .{ "Text", .text },              .{ "Expression", .expression }, .{ "Comment", .comment },
        .{ "Doctype", .doctype },        .{ "Script", .script },         .{ "Style", .style },
        .{ "ClosingTag", .closing_tag },
    });
    const index = try tree.addNode(.{ .dialect = .{
        .kind = kinds.get(node.type_name).?,
        .children = try tree.addExtra(children.items),
    } }, .{ .start = node.start orelse 0, .end = node.end orelse 0 });
    document.tree_nodes.items[id] = index;
    return index;
}

// resolve template references through the document program and preserve component bindings
test "dialect document shares frontmatter bindings with template expressions and tags" {
    const source = "---\r\nimport Card from './Card.astro';\r\n" ++
        "export const value = await Promise.resolve('😀'); return;\r\n---\r\n" ++
        "😀<Card title={value}>{value}</Card>{value && <p>{value}</p>}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var session: Session = undefined;
    try session.init(arena.allocator(), source, false);
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.document.diagnostics.items.len);
    try std.testing.expectEqual(.program, std.meta.activeTag(session.tree.data(session.tree.root)));
    const model = try yuku.semantic.analyze(&session.tree, .{ .check = true });
    try std.testing.expect(!session.tree.hasErrors());
    var resolved: u32 = 0;
    for (model.references) |reference| {
        const name = session.tree.string(reference.name);
        if (std.mem.eql(u8, name, "value") or std.mem.eql(u8, name, "Card")) {
            try std.testing.expect(reference.symbol != .none);
            resolved += 1;
        }
    }
    try std.testing.expectEqual(@as(u32, 5), resolved);
}

// a discarded speculative candidate never changes committed host metadata or child lists
test "dialect rewind discards host views and replaces candidates when node indexes are reused" {
    const source = "<A/>{value}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var session: Session = undefined;
    session.pending = .empty;
    session.pending_epoch = 0;
    session.candidates = .empty;
    session.candidate_depth = 0;
    session.connect_stack = .empty;
    session.connect_seen = .empty;
    session.document.init(allocator, source);
    session.document.session = &session;
    session.active_document = &session.document;
    session.tree = yuku.ast.Tree.initInArena(allocator, source);
    const options = session.document.options(false);
    try session.body_parser.initInTree(&session.tree, options, .{ .start = 0, .end = source.len });
    defer session.body_parser.deinit();
    session.document.body_parser = &session.body_parser;
    var facade: yuku.dialect.Parser = .{ .inner = &session.body_parser };
    const checkpoint = facade.checkpoint();
    const discarded = try expression(&facade);
    try std.testing.expect(discarded == .node);
    try std.testing.expectEqual(@as(usize, 0), session.document.nodes.items.len);
    facade.rewind(checkpoint);
    try std.testing.expectEqual(@as(usize, 0), session.tree.nodes.len);
    const saved = try session.body_parser.enterRange(.{ .start = 5, .end = source.len }, options);
    const identifier = try session.body_parser.parseDelimitedExpression(&.{
        .start = 5,
        .terminator = .right_brace,
    });
    try connect(&session.document, identifier, 0);
    try std.testing.expectEqual(@as(usize, 0), session.document.nodes.items.len);
    session.body_parser.leaveRange(&saved);
    facade.rewind(checkpoint);
    const epoch = session.pending_epoch;
    const committed = try expression(&facade);
    try std.testing.expect(committed == .node);
    try connect(&session.document, committed.node, epoch);
    try std.testing.expectEqual(@as(usize, 1), session.document.nodes.items.len);
    try std.testing.expectEqualStrings("A", session.document.nodes.items[0].name.?);
    try std.testing.expectEqual(committed.node, session.document.tree_nodes.items[0]);
}

// the document arena releases every temporary candidate on allocation failure
test "dialect documents release shared storage after every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationCase, .{});
}

fn allocationCase(allocator: std.mem.Allocator) !void {
    const source = "---\nconst value=1;\n---\n" ++
        "{value ? <Card title={value}><p>{value}</p></Card> : <br>}";
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var session: Session = undefined;
    try session.init(arena.allocator(), source, false);
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.document.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.document.embedded_roots.items.len);
}
