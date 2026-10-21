const std = @import("std");
const yuku = @import("parser");
const wire = @import("yuku_transfer");
const native = @import("native_parser.zig");
const types = @import("astro_types.zig");
const Session = @import("astro_parse.zig").ParseSession;

pub const magic: u32 = 0x41535452;
pub const version: u32 = 2;
pub const header_size: u32 = 12;
pub const dictionary = [_][]const u8{
    "Element",     "Component", "Fragment",   "Text",     "Expression", "Comment",   "Doctype", "Script",  "Style", "ClosingTag",
    "boolean",     "string",    "expression", "template", "spread",     "shorthand", "error",   "warning", "hint",  "info",
    "frontmatter", "line",      "block",
};
const strings = std.StaticStringMap(u8).initComptime(blk: {
    var entries: [dictionary.len]struct { []const u8, u8 } = undefined;
    for (dictionary, 0..) |value, index| entries[index] = .{ value, @intCast(index) };
    break :blk entries;
});

/// Byte size of one ArrayBuffer containing Yuku records and the Astro document.
pub fn bufferSize(session: *const Session) !usize {
    var writer = Writer{ .source = session.document.source, .buffer = null };
    try writer.writeDocument(&session.document, &session.tree);
    const size = header_size + wire.bufferSize(&session.tree) + writer.cursor;
    if (size > std.math.maxInt(u32)) return error.TransferTooLarge;
    return size;
}

/// Writes directly to host-owned memory without an intermediate JSON object graph.
pub fn serializeInto(session: *const Session, buffer: []u8) !void {
    std.debug.assert(@intFromPtr(buffer.ptr) % 4 == 0);
    const tree_size = wire.bufferSize(&session.tree);
    std.debug.assert(buffer.len >= header_size + tree_size);
    std.mem.writeInt(u32, buffer[0..4], magic, .little);
    std.mem.writeInt(u32, buffer[4..8], version, .little);
    std.mem.writeInt(u32, buffer[8..12], @intCast(tree_size), .little);
    _ = wire.serializeInto(&session.tree, buffer[header_size..][0..tree_size]);
    var writer = Writer{ .source = session.document.source, .buffer = buffer[header_size + tree_size ..] };
    try writer.writeDocument(&session.document, &session.tree);
    std.debug.assert(writer.cursor == writer.buffer.?.len);
}

const Writer = struct {
    source: []const u8,
    buffer: ?[]u8,
    cursor: usize = 0,

    fn bytes(self: *Writer, value: []const u8) !void {
        if (self.buffer) |buffer| @memcpy(buffer[self.cursor..][0..value.len], value);
        self.cursor = try std.math.add(usize, self.cursor, value.len);
    }

    fn byte(self: *Writer, value: u8) !void {
        if (self.buffer) |buffer| buffer[self.cursor] = value;
        self.cursor = try std.math.add(usize, self.cursor, 1);
    }

    fn integer(self: *Writer, value: u32) !void {
        if (self.buffer) |buffer| std.mem.writeInt(u32, buffer[self.cursor..][0..4], value, .little);
        self.cursor = try std.math.add(usize, self.cursor, 4);
    }

    fn string(self: *Writer, value: []const u8) !void {
        const address = @intFromPtr(value.ptr);
        const base = @intFromPtr(self.source.ptr);
        if (address >= base and address - base <= self.source.len and value.len <= self.source.len - (address - base)) {
            try self.byte(0);
            try self.integer(@intCast(address - base));
            try self.integer(@intCast(address - base + value.len));
        } else if (strings.get(value)) |index| {
            try self.byte(1);
            try self.byte(index);
        } else {
            try self.byte(2);
            try self.integer(@intCast(value.len));
            try self.bytes(value);
        }
    }

    fn writeValue(self: *Writer, item: anytype) error{ OutOfMemory, Overflow }!void {
        const T = @TypeOf(item);
        switch (@typeInfo(T)) {
            .bool => try self.byte(@intFromBool(item)),
            .int => try self.integer(@intCast(item)),
            .optional => {
                try self.byte(@intFromBool(item != null));
                if (item) |some| try self.writeValue(some);
            },
            .pointer => |pointer| {
                if (pointer.child == u8) return self.string(item);
                try self.integer(@intCast(item.len));
                for (item) |*child| {
                    if (@typeInfo(pointer.child) == .@"struct") try self.record(child) else try self.writeValue(child.*);
                }
            },
            .@"struct" => try self.record(&item),
            else => @compileError("Unsupported Astro wire value " ++ @typeName(T)),
        }
    }

    fn record(self: *Writer, item: anytype) error{ OutOfMemory, Overflow }!void {
        const T = @typeInfo(@TypeOf(item)).pointer.child;
        inline for (@import("meta").fields(T)) |field| {
            try self.writeValue(@field(item, field.name));
        }
    }

    fn root(self: *Writer, item: ?u32) !void {
        try self.byte(@intFromBool(item != null));
        if (item) |some| try self.integer(some);
    }

    fn writeDocument(self: *Writer, document: *const native.Document, tree: *const yuku.ast.Tree) !void {
        try self.integer(@intCast(document.template_start));
        try self.byte(@intFromBool(document.frontmatter != null));
        if (document.frontmatter) |frontmatter| {
            try self.integer(frontmatter.start);
            try self.integer(frontmatter.end);
            try self.integer(document.frontmatter_root.?);
        }
        try self.integer(@intCast(document.nodes.items.len));
        const nodes_end_offset = self.cursor;
        try self.integer(0);
        const index_offset = self.cursor;
        self.cursor = try std.math.add(usize, self.cursor, try std.math.mul(usize, document.nodes.items.len, 8));
        var failed: u32 = 0;
        for (document.nodes.items, 0..) |*node, index| {
            const start = self.cursor;
            var suffix: usize = undefined;
            inline for (@import("meta").fields(types.AstroNode)) |field| {
                try self.writeValue(@field(node.*, field.name));
                if (comptime std.mem.eql(u8, field.name, "attributes")) suffix = self.cursor;
            }
            if (self.buffer) |buffer| {
                const entry = buffer[index_offset + index * 8 ..][0..8];
                std.mem.writeInt(u32, entry[0..4], @intCast(start), .little);
                std.mem.writeInt(u32, entry[4..8], @intCast(suffix), .little);
            }
            if (node.parse_failed) failed += 1;
            try self.root(document.javascript_roots.items[index]);
            try self.root(document.type_argument_roots.items[index]);
        }
        if (self.buffer) |buffer| std.mem.writeInt(u32, buffer[nodes_end_offset..][0..4], @intCast(self.cursor), .little);
        try self.integer(failed);
        if (failed != 0) {
            for (document.nodes.items, 0..) |node, index| {
                if (node.parse_failed) try self.integer(@intCast(index));
            }
        }
        try self.writeValue(document.roots.items);
        try self.integer(@intCast(document.js_comments.items.len));
        for (document.js_comments.items) |comment| {
            const object = comment.object;
            const span = object.get("span").?.object;
            try self.string(object.get("type").?.string);
            try self.integer(@intCast(span.get("start").?.integer));
            try self.integer(@intCast(span.get("end").?.integer));
            try self.string(object.get("value").?.string);
        }
        try self.writeValue(document.diagnostics.items);
        _ = tree;
        try self.integer(document.embedded.count());
        var links = document.embedded.iterator();
        while (links.next()) |entry| {
            try self.integer(@backingInt(entry.key_ptr.*));
            try self.integer(entry.value_ptr.*);
        }
    }
};
