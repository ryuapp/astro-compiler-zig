const std = @import("std");
const yuku = @import("parser");
const maps = @import("transform_sourcemap.zig");

pub const Result = struct { code: []const u8, shifts: []const maps.Expansion };

pub fn legacy(allocator: std.mem.Allocator, tree: *const yuku.ast.Tree, code: []const u8) !Result {
    var found = false;
    std.debug.assert(tree.data(tree.root) == .program);
    for (tree.extra(tree.data(tree.root).program.body)) |id| {
        if (attributes(tree.data(id)).len > 0) {
            found = true;
            break;
        }
    }
    if (!found) return .{ .code = code, .shifts = &.{} };

    // locate only declaration keywords so strings and comments keep their text
    var printed = try yuku.parse(allocator, code, .{
        .lang = .js,
        .tokens = true,
        .comments = .none,
    });
    defer printed.deinit();
    std.debug.assert(!printed.hasErrors());
    var keywords: std.ArrayList(yuku.ast.Span) = .empty;
    defer keywords.deinit(allocator);
    for (printed.nodes.items(.data), printed.nodes.items(.span)) |data, span| {
        const attrs = attributes(data);
        if (attrs.len == 0) continue;
        const source: yuku.ast.NodeIndex = switch (data) {
            .import_declaration => |value| value.source,
            .export_named_declaration => |value| value.source,
            .export_all_declaration => |value| value.source,
            else => unreachable,
        };
        const after_source = printed.span(source).end;
        const first = printed.span(printed.extra(attrs)[0]).start;
        for (printed.tokens) |token| {
            if (token.span.start < @max(span.start, after_source)) continue;
            if (token.span.end > first) break;
            if (token.tag == .with) try keywords.append(allocator, token.span);
        }
    }
    std.mem.sort(yuku.ast.Span, keywords.items, {}, struct {
        fn less(_: void, a: yuku.ast.Span, b: yuku.ast.Span) bool {
            return a.start < b.start;
        }
    }.less);
    var output: std.ArrayList(u8) = .empty;
    var shifts: std.ArrayList(maps.Expansion) = .empty;
    var previous: u32 = 0;
    for (keywords.items) |span| {
        std.debug.assert(previous <= span.start);
        std.debug.assert(std.mem.eql(u8, code[span.start..span.end], "with"));
        try output.appendSlice(allocator, code[previous..span.start]);
        try output.appendSlice(allocator, "assert");
        try shifts.append(allocator, .{ .at = maps.lineCol(code, span.end), .columns = 2 });
        previous = span.end;
    }
    try output.appendSlice(allocator, code[previous..]);
    return .{ .code = try output.toOwnedSlice(allocator), .shifts = try shifts.toOwnedSlice(allocator) };
}

fn attributes(data: yuku.ast.NodeData) yuku.ast.IndexRange {
    return switch (data) {
        .import_declaration => |value| value.attributes,
        .export_named_declaration => |value| value.attributes,
        .export_all_declaration => |value| value.attributes,
        else => .empty,
    };
}
