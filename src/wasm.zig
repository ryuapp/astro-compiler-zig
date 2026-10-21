const std = @import("std");
const astro = @import("astro");

var arena = std.heap.ArenaAllocator.init(std.heap.wasm_allocator);
var input: []u8 = &.{};
var output_size: u32 = 0;
var failure: []const u8 = "";

fn fail(err: anyerror) u32 {
    failure = @errorName(err);
    return 0;
}

export fn error_pointer() u32 {
    return @intCast(@intFromPtr(failure.ptr));
}

export fn error_length() u32 {
    return @intCast(failure.len);
}

export fn prepare(length: u32) u32 {
    failure = "";
    output_size = 0;
    const size = std.math.add(usize, length, 1) catch |err| return fail(err);
    input = arena.allocator().alignedAlloc(u8, .@"4", size) catch |err| return fail(err);
    input[length] = 0;
    return @intCast(@intFromPtr(input.ptr));
}

export fn parse(length: u32, editor: u32) u32 {
    var session: astro.ParseSession = undefined;
    session.init(arena.allocator(), input[0..length], editor != 0) catch |err| return fail(err);
    defer session.deinit();
    const size = astro.transfer.bufferSize(&session) catch |err| return fail(err);
    const output = arena.allocator().alignedAlloc(u8, .@"4", size) catch |err| return fail(err);
    astro.transfer.serializeInto(&session, output) catch |err| return fail(err);
    output_size = @intCast(size);
    return @intCast(@intFromPtr(output.ptr));
}

export fn result_size() u32 {
    return output_size;
}

// TSX strings can contain lone UTF-16 units. A small binary value format preserves
// those units, null fields and numeric arrays without a JSON round trip.
const Writer = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn byte(self: *Writer, value: u8) !void {
        try self.bytes.append(arena.allocator(), value);
    }

    fn integer(self: *Writer, value: u32) !void {
        var encoded: [4]u8 = undefined;
        std.mem.writeInt(u32, &encoded, value, .little);
        try self.bytes.appendSlice(arena.allocator(), &encoded);
    }

    fn string(self: *Writer, value: []const u8) !void {
        const units = try std.unicode.wtf8ToWtf16LeAlloc(arena.allocator(), value);
        try self.integer(@intCast(units.len * 2));
        try self.bytes.appendSlice(arena.allocator(), std.mem.sliceAsBytes(units));
    }

    fn write(self: *Writer, value: anytype) anyerror!void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .bool => try self.byte(if (value) 2 else 1),
            .int => {
                try self.byte(3);
                var encoded: [8]u8 = undefined;
                std.mem.writeInt(u64, &encoded, @bitCast(@as(f64, @floatFromInt(value))), .little);
                try self.bytes.appendSlice(arena.allocator(), &encoded);
            },
            .optional => {
                if (value) |some| try self.write(some) else try self.byte(0);
            },
            .pointer => |pointer| {
                if (pointer.size != .slice) @compileError("WASM conversion requires slices");
                if (pointer.child == u8) {
                    try self.byte(4);
                    try self.string(value);
                } else {
                    try self.byte(5);
                    try self.integer(@intCast(value.len));
                    for (value) |item| try self.write(item);
                }
            },
            .@"struct" => {
                try self.byte(6);
                const fields = @import("meta").fields(T);
                try self.integer(fields.len);
                inline for (fields) |field| {
                    try self.string(field.name);
                    try self.write(@field(value, field.name));
                }
            },
            else => @compileError("Unsupported WASM value " ++ @typeName(T)),
        }
    }
};

fn result(value: anytype) u32 {
    var writer: Writer = .{};
    writer.write(value) catch |err| return fail(err);
    output_size = @intCast(writer.bytes.items.len);
    return @intCast(@intFromPtr(writer.bytes.items.ptr));
}

export fn convert_to_tsx(length: u32, filename_length: u32, has_filename: u32, ambient: u32) u32 {
    const units = std.mem.bytesAsSlice(u16, input[0..length]);
    const source = std.unicode.wtf16LeToWtf8Alloc(arena.allocator(), @alignCast(units)) catch |err| return fail(err);
    const converted = astro.convertToTsx(arena.allocator(), source, .{
        .filename = if (has_filename != 0) input[length..][0..filename_length] else null,
        .ambient_types = ambient != 0,
    }) catch |err| return fail(err);
    return result(converted);
}

export fn transform(length: u32, options_length: u32) u32 {
    const options = std.json.parseFromSlice(astro.TransformOptions, arena.allocator(), input[length..][0..options_length], .{ .allocate = .alloc_always }) catch |err| return fail(err);
    return result(astro.transform(arena.allocator(), input[0..length], options.value) catch |err| return fail(err));
}

export fn extract_styles(length: u32) u32 {
    return result(astro.extractStyles(arena.allocator(), input[0..length]) catch |err| return fail(err));
}

export fn release() void {
    // JS has copied every result before the next operation can reuse this arena.
    _ = arena.reset(.retain_capacity);
}
