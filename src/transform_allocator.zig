const std = @import("std");
const Allocator = std.mem.Allocator;
/// A call-local bump allocator over a reservation owned by the backing arena.
/// Overflow uses the same arena, which releases both regions after the call.
pub fn init(backing: Allocator, capacity: usize) std.heap.BufferFirstAllocator {
    return .init(backing.alloc(u8, capacity) catch &.{}, backing);
}

test "call-local allocations preserve alignment and data across arena overflow" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var scratch = init(arena.allocator(), 128);
    const memory = scratch.allocator();
    const first = try memory.alignedAlloc(u8, .@"64", 32);
    @memset(first, 0x7b);
    const second = try memory.alloc(u8, 256);
    @memset(second, 0x5a);
    const grown = try memory.realloc(first, 512);
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x7b)), grown[0..32]);
    try std.testing.expectEqualSlices(u8, &@as([256]u8, @splat(0x5a)), second);
    try std.testing.expect(memory.resize(grown, 64));
    memory.free(grown[0..64]);
    memory.free(second);
    const reused = try memory.alignedAlloc(u8, .@"64", 64);
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(reused.ptr) % 64);
}

test "failed reservation falls back without consuming the caller's storage" {
    var storage: [64]u8 = undefined;
    var backing = std.heap.FixedBufferAllocator.init(&storage);
    var scratch = init(backing.allocator(), 128);
    const memory = scratch.allocator();
    const value = try memory.alloc(u8, 32);
    @memset(value, 0x42);
    try std.testing.expectError(error.OutOfMemory, memory.alloc(u8, 128));
    try std.testing.expectEqualSlices(u8, &@as([32]u8, @splat(0x42)), value);
    memory.free(value);
    _ = try memory.alloc(u8, 64);
}
