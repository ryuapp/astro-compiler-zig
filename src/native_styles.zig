const std = @import("std");
const native = @import("native_parser.zig");
const types = @import("astro_types.zig");
const text = @import("tsx_text.zig");
const Allocator = std.mem.Allocator;

const StyleAttribute = struct { name: []const u8, value: []const u8 };
pub const StyleBlock = struct {
    index: u32,
    content: []const u8,
    attrs: []const StyleAttribute,
};

/// Extract using the same Yuku parse and hoisting rules as transform.
/// The caller supplies an arena covering the returned arrays and source slices.
pub fn extract(allocator: Allocator, source: []const u8) ![]const StyleBlock {
    var session: @import("astro_parse.zig").ParseSession = undefined;
    try session.initForStyles(allocator, source);
    defer session.deinit();
    for (session.document.diagnostics.items) |diagnostic| {
        if (text.eql(diagnostic.severity, "error")) return &.{};
    }
    const ids = try collect(allocator, &session.document);
    const blocks = try allocator.alloc(StyleBlock, ids.len);
    for (ids, blocks, 0..) |id, *block, index| {
        const node = &session.document.nodes.items[id];
        var attrs: std.ArrayList(StyleAttribute) = .empty;
        for (node.attributes) |attr| {
            if (!text.in(attr.kind, &.{ "boolean", "quoted", "unquoted" })) continue;
            try attrs.append(allocator, .{ .name = attr.name orelse continue, .value = attr.value orelse "" });
        }
        block.* = .{ .index = @intCast(index), .content = node.value orelse "", .attrs = try attrs.toOwnedSlice(allocator) };
    }
    return blocks;
}

pub fn attribute(node: anytype, name: []const u8) ?types.AstroAttribute {
    for (node.attributes) |item| if (text.eql(item.name orelse "", name)) return item;
    return null;
}

pub fn extractable(node: types.AstroNode) bool {
    return text.eql(node.name orelse "", "style") and attribute(node, "is:inline") == null and
        attribute(node, "set:html") == null and attribute(node, "set:text") == null;
}

pub fn blocked(node: types.AstroNode) bool {
    const name = node.name orelse "";
    return text.eql(name, "svg") or text.eql(name, "noscript") or text.eql(name, "template") or text.eql(node.type_name, "Expression");
}

pub fn collect(allocator: Allocator, document: *const native.Document) ![]const u32 {
    var result: std.ArrayList(u32) = .empty;
    var pending: std.ArrayList(u32) = .empty;
    var i = document.roots.items.len;
    while (i > 0) {
        i -= 1;
        try pending.append(allocator, document.roots.items[i]);
    }
    while (pending.pop()) |id| {
        const node = document.nodes.items[id];
        if (extractable(node)) {
            try result.append(allocator, id);
        } else if (!blocked(node)) {
            i = node.children.len;
            while (i > 0) {
                i -= 1;
                try pending.append(allocator, node.children[i]);
            }
        }
    }
    return result.toOwnedSlice(allocator);
}
