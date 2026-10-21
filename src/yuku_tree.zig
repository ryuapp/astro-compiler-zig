const std = @import("std");
const yuku = @import("parser");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

/// Copy Yuku's data without converting node kinds, child IDs or string handles.
/// The result and all of its strings share the supplied arena's lifetime.
pub fn exportTree(allocator: Allocator, tree: *const yuku.ast.Tree) error{OutOfMemory}!Value {
    var result = object(allocator);
    try put(allocator, &result, "root", try value(allocator, tree.root));
    var nodes = array(allocator);
    for (tree.nodes.items(.data), tree.nodes.items(.span)) |data, span| {
        var node = object(allocator);
        try put(allocator, &node, "data", try value(allocator, data));
        try put(allocator, &node, "span", try value(allocator, span));
        try nodes.array.append(node);
    }
    try put(allocator, &result, "nodes", nodes);
    try put(allocator, &result, "extras", try value(allocator, tree.extras.items));
    try put(allocator, &result, "source", try value(allocator, tree.source));
    var strings = object(allocator);
    // Byte values preserve lone surrogates and all original String handles.
    var extra = array(allocator);
    for (tree.strings.extra.items) |byte| try extra.array.append(.{ .integer = byte });
    try put(allocator, &strings, "extra", extra);
    try put(allocator, &result, "strings", strings);
    inline for (.{ "source_type", "lang", "comments", "tokens" }) |field| {
        try put(allocator, &result, field, try value(allocator, @field(tree, field)));
    }
    try put(allocator, &result, "diagnostics", try value(allocator, tree.diagnostics.items));
    return result;
}

pub fn object(allocator: Allocator) Value {
    _ = allocator;
    return .{ .object = .{} };
}

pub fn array(allocator: Allocator) Value {
    return .{ .array = std.array_list.Managed(Value).init(allocator) };
}

pub fn put(allocator: Allocator, target: *Value, name: []const u8, item: Value) !void {
    try target.object.put(allocator, try allocator.dupe(u8, name), item);
}

/// Tagged unions use one key containing the original tag and its full payload.
/// Recursion follows bounded payload types, never AST child references.
pub fn value(allocator: Allocator, item: anytype) error{OutOfMemory}!Value {
    return encode(allocator, item, false);
}

pub fn nativeValue(allocator: Allocator, item: anytype) error{OutOfMemory}!Value {
    return encode(allocator, item, true);
}

fn camelName(comptime name: []const u8) []const u8 {
    comptime {
        var result: []const u8 = "";
        var uppercase = false;
        for (name) |character| {
            if (character == '_') {
                uppercase = true;
            } else {
                result = result ++ [1]u8{if (uppercase) std.ascii.toUpper(character) else character};
                uppercase = false;
            }
        }
        return result;
    }
}

fn encode(allocator: Allocator, item: anytype, comptime camel_fields: bool) error{OutOfMemory}!Value {
    @setEvalBranchQuota(30000);
    const T = @TypeOf(item);
    if (T == yuku.ast.NodeIndex) return .{ .integer = @backingInt(item) };
    switch (@typeInfo(T)) {
        .void => return .null,
        .bool => return .{ .bool = item },
        .int, .comptime_int => return .{ .integer = @intCast(item) },
        .float, .comptime_float => return .{ .float = @floatCast(item) },
        .@"enum" => return .{ .string = try allocator.dupe(u8, @tagName(item)) },
        .optional => return if (item) |some| encode(allocator, some, camel_fields) else .null,
        .@"union" => {
            var result = object(allocator);
            switch (item) {
                inline else => |payload, tag| {
                    try put(allocator, &result, @tagName(tag), try encode(allocator, payload, camel_fields));
                },
            }
            return result;
        },
        .@"struct" => {
            var result = object(allocator);
            inline for (@import("meta").fields(T)) |field| {
                const name = if (camel_fields) comptime camelName(field.name) else field.name;
                try put(allocator, &result, name, try encode(allocator, @field(item, field.name), camel_fields));
            }
            return result;
        },
        .pointer => |pointer| {
            if (pointer.size != .slice) @compileError("Expected a slice");
            if (pointer.child == u8) return .{ .string = try allocator.dupe(u8, item) };
            var result = array(allocator);
            for (item) |element| try result.array.append(try encode(allocator, element, camel_fields));
            return result;
        },
        .array => {
            var result = array(allocator);
            for (item) |element| try result.array.append(try encode(allocator, element, camel_fields));
            return result;
        },
        else => @compileError("Unsupported Yuku payload " ++ @typeName(T)),
    }
}

test "Yuku snapshot retains string handles after its source and tree are released" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const source = try std.testing.allocator.dupe(u8, "'\\uD800'");
    defer std.testing.allocator.free(source);
    var parsed = try yuku.parseExpression(std.testing.allocator, source, &.{
        .options = .{ .tokens = true },
    });
    const root = @backingInt(parsed.tree.root);
    const literal = parsed.tree.data(parsed.tree.root).string_literal;
    const exported = exportTree(arena.allocator(), &parsed.tree) catch |err| {
        parsed.tree.deinit();
        return err;
    };
    parsed.tree.deinit();
    @memset(source, 'x');
    try std.testing.expectEqualStrings("'\\uD800'", exported.object.get("source").?.string);
    try std.testing.expectEqual(@as(i64, root), exported.object.get("root").?.integer);
    const data = exported.object.get("nodes").?.array.items[root].object.get("data").?;
    const handles = data.object.get("string_literal").?.object;
    try std.testing.expectEqual(@as(i64, literal.value.start), handles.get("value").?.object.get("start").?.integer);
    try std.testing.expectEqual(@as(i64, literal.raw.end), handles.get("raw").?.object.get("end").?.integer);
    const extra = exported.object.get("strings").?.object.get("extra").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), extra.len);
    for (extra, [_]u8{ 0xed, 0xa0, 0x80 }) |byte, expected| {
        try std.testing.expectEqual(@as(i64, expected), byte.integer);
    }
    try std.testing.expectEqualStrings("string_literal", exported.object.get("tokens").?.array.items[0].object.get("tag").?.string);
}
