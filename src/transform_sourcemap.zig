const std = @import("std");
const text = @import("tsx_text.zig");
const utf = @import("util").Utf;
const Allocator = std.mem.Allocator;
const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const digits = blk: {
    var values: [256]u8 = @splat(0xff);
    for (alphabet, 0..) |c, i| values[c] = @intCast(i);
    break :blk values;
};
pub const Copy = struct { generated: u32, original: u32, length: u32 };
pub const Anchor = struct { start: u32, end: u32, point: u32, multiline: bool = false };
pub const Quasi = struct { start: u32, end: u32 };
const Point = struct { generated: Position, original: Position };
pub const Position = struct { line: u32 = 0, column: u32 = 0 };
pub const Expansion = struct { at: Position, columns: u32 };

pub fn lineCol(source: []const u8, end: usize) Position {
    var result: Position = .{};
    var i: usize = 0;
    while (i < @min(end, source.len)) {
        const c = source[i];
        const separator = utf.unicodeSeparatorLen(source[0..@min(end, source.len)], i);
        if (c == '\r' or c == '\n' or separator > 0) {
            if (c == '\r' and i + 1 < end and source[i + 1] == '\n') i += 1;
            result.line += 1;
            result.column = 0;
            i += if (separator > 0) separator else 1;
        } else {
            result.column += if (text.cpAt(source, i) > 0xffff) @as(u32, 2) else 1;
            i += text.cpLen(source, i);
        }
    }
    return result;
}

// Keep byte positions until the final map is encoded. Index line starts and
// UTF-8/UTF-16 differences once instead of rescanning source prefixes per point.
const SourceIndex = struct {
    const Line = struct { start: u32, units: u32, crlf: bool = false, wide: bool = false };
    const Wide = struct { start: u32, end: u32, units_start: u32, units_end: u32 };

    source: []const u8,
    lines: []const Line,
    wide: []const Wide,
    units: u32,
    last_line: usize = 0,

    fn init(allocator: Allocator, source: []const u8) !SourceIndex {
        return initWithLines(allocator, source, true);
    }

    fn initWithLines(allocator: Allocator, source: []const u8, comptime index_lines: bool) !SourceIndex {
        var lines: std.ArrayList(Line) = .empty;
        var wide: std.ArrayList(Wide) = .empty;
        if (index_lines) try lines.append(allocator, .{ .start = 0, .units = 0 });
        var i: usize = 0;
        var units: u32 = 0;
        while (i < source.len) {
            const lanes = std.simd.suggestVectorLength(u8) orelse 1;
            if (comptime lanes > 1) {
                if (i + lanes <= source.len) {
                    const bytes: @Vector(lanes, u8) = source[i..][0..lanes].*;
                    const special = (bytes >= @as(@Vector(lanes, u8), @splat(0x80))) |
                        (if (index_lines) (bytes == @as(@Vector(lanes, u8), @splat('\r'))) | (bytes == @as(@Vector(lanes, u8), @splat('\n'))) else @as(@Vector(lanes, bool), @splat(false)));
                    const mask: @Int(.unsigned, lanes) = @bitCast(special);
                    const run: usize = if (@import("builtin").cpu.arch.endian() == .little) @ctz(mask) else @clz(mask);
                    i += run;
                    units += @intCast(run);
                    if (run == lanes) continue;
                }
            }
            const c = source[i];
            const separator = if (index_lines) utf.unicodeSeparatorLen(source, i) else 0;
            if (c == '\r' or c == '\n' or separator > 0) {
                const crlf = c == '\r' and i + 1 < source.len and source[i + 1] == '\n';
                const length: u32 = if (separator > 0) separator else if (crlf) 2 else 1;
                if (separator > 0) {
                    lines.items[lines.items.len - 1].wide = true;
                    try wide.append(allocator, .{ .start = @intCast(i), .end = @intCast(i + length), .units_start = units, .units_end = units + 1 });
                }
                i += length;
                units += if (separator > 0) 1 else length;
                if (index_lines) try lines.append(allocator, .{ .start = @intCast(i), .units = units, .crlf = crlf });
            } else if (c < 0x80) {
                i += 1;
                units += 1;
            } else {
                const length = text.cpLen(source, i);
                const width: u32 = if (text.cpAt(source, i) > 0xffff) 2 else 1;
                if (length != width) {
                    if (index_lines) lines.items[lines.items.len - 1].wide = true;
                    try wide.append(allocator, .{
                        .start = @intCast(i),
                        .end = @intCast(i + length),
                        .units_start = units,
                        .units_end = units + width,
                    });
                }
                i += length;
                units += width;
            }
        }
        return .{ .source = source, .lines = lines.items, .wide = wide.items, .units = units };
    }

    fn unitsAt(self: SourceIndex, byte: u32) u32 {
        if (self.wide.len == 0) return byte;
        const last = self.wide[self.wide.len - 1];
        if (byte >= last.end) return byte - last.end + last.units_end;
        var low: usize = 0;
        var high = self.wide.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.wide[mid].start < byte) low = mid + 1 else high = mid;
        }
        if (low == 0) return byte;
        const item = self.wide[low - 1];
        return @max(byte, item.end) - item.end + item.units_end;
    }

    fn position(self: *SourceIndex, end: usize) Position {
        const byte: u32 = @intCast(@min(end, self.source.len));
        var line_index = self.last_line;
        if (byte < self.lines[line_index].start or (line_index + 1 < self.lines.len and byte >= self.lines[line_index + 1].start)) {
            const next = line_index + 1;
            if (next < self.lines.len and byte >= self.lines[next].start and
                (next + 1 == self.lines.len or byte < self.lines[next + 1].start))
            {
                line_index = next;
            } else if (line_index > 0 and byte < self.lines[line_index].start and byte >= self.lines[line_index - 1].start) {
                line_index -= 1;
            } else {
                var low: usize = 0;
                var high = self.lines.len;
                while (low < high) {
                    const mid = low + (high - low) / 2;
                    if (self.lines[mid].start <= byte) low = mid + 1 else high = mid;
                }
                line_index = low - 1;
            }
            self.last_line = line_index;
        }
        // A position between CR and LF already belongs to the next line.
        const next = line_index + 1;
        if (next < self.lines.len and self.lines[next].crlf and self.lines[next].start - 1 == byte) {
            return .{ .line = @intCast(next) };
        }
        const line = self.lines[line_index];
        return .{ .line = @intCast(line_index), .column = if (line.wide) self.unitsAt(byte) - line.units else byte - line.start };
    }

    fn advance(self: SourceIndex, start: u32, columns: u32) u32 {
        const units: u32 = @intCast(@min(@as(u64, self.unitsAt(start)) + columns, self.units));
        if (self.wide.len == 0) return units;
        const last = self.wide[self.wide.len - 1];
        if (units >= last.units_end) return units - last.units_end + last.end;
        var low: usize = 0;
        var high = self.wide.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (self.wide[mid].units_start < units) low = mid + 1 else high = mid;
        }
        if (low == 0) return units;
        const item = self.wide[low - 1];
        return @max(units, item.units_end) - item.units_end + item.end;
    }
};

// Printer mappings commonly stay in the same copied range. Cache the upper
// bound, with a binary-search fallback for reordered code and duplicate starts.
const CopyIndex = struct {
    copies: []const Copy,
    upper: usize = 0,

    fn find(self: *CopyIndex, offset: u32) ?Copy {
        var upper = self.upper;
        if ((upper > 0 and self.copies[upper - 1].generated > offset) or
            (upper < self.copies.len and self.copies[upper].generated <= offset))
        {
            if (upper < self.copies.len and self.copies[upper].generated <= offset and
                (upper + 1 == self.copies.len or self.copies[upper + 1].generated > offset))
            {
                upper += 1;
            } else {
                var low: usize = 0;
                var high = self.copies.len;
                while (low < high) {
                    const mid = low + (high - low) / 2;
                    if (self.copies[mid].generated <= offset) low = mid + 1 else high = mid;
                }
                upper = low;
            }
            self.upper = upper;
        }
        return if (upper > 0) self.copies[upper - 1] else null;
    }
};

// Search later anchors first, preserving their precedence even when ranges
// overlap or were recorded out of source order. Disjoint subtrees are skipped.
const AnchorIndex = struct {
    const Bounds = struct { start: u32, end: u32 };
    anchors: []const Anchor,
    bounds: []const Bounds,
    leaves: usize,

    fn init(allocator: Allocator, anchors: []const Anchor) !AnchorIndex {
        var leaves: usize = 1;
        while (leaves < anchors.len) leaves *= 2;
        const bounds = try allocator.alloc(Bounds, leaves * 2);
        for (bounds[leaves..], 0..) |*item, i| {
            item.* = if (i < anchors.len) .{ .start = anchors[i].start, .end = anchors[i].end } else .{ .start = std.math.maxInt(u32), .end = 0 };
        }
        var i = leaves;
        while (i > 1) {
            i -= 1;
            bounds[i] = .{ .start = @min(bounds[i * 2].start, bounds[i * 2 + 1].start), .end = @max(bounds[i * 2].end, bounds[i * 2 + 1].end) };
        }
        return .{ .anchors = anchors, .bounds = bounds, .leaves = leaves };
    }

    fn find(self: AnchorIndex, offset: u32) ?Anchor {
        var i: usize = 1;
        while (true) {
            const range = self.bounds[i];
            if (offset < range.start or offset > range.end) {
                while (i > 1 and i % 2 == 0) i /= 2;
                if (i == 1) return null;
                i -= 1;
            } else if (i >= self.leaves) {
                return self.anchors[i - self.leaves];
            } else i = i * 2 + 1;
        }
    }
};

inline fn vlq(out: *std.ArrayList(u8), delta: i64) void {
    var value: u64 = if (delta < 0) (@as(u64, @intCast(-delta)) << 1) | 1 else @as(u64, @intCast(delta)) << 1;
    while (true) {
        var digit: usize = @intCast(value & 31);
        value >>= 5;
        if (value > 0) digit |= 32;
        out.appendAssumeCapacity(alphabet[digit]);
        if (value == 0) return;
    }
}
inline fn decode(source: []const u8, pos: *usize) i64 {
    if (pos.* == source.len) return 0;
    const digit = digits[source[pos.*]];
    if (digit < 32) {
        pos.* += 1;
        const magnitude: i64 = digit >> 1;
        return if (digit & 1 == 1) -magnitude else magnitude;
    }
    return decodeLong(source, pos);
}

fn decodeLong(source: []const u8, pos: *usize) i64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (pos.* < source.len) {
        const digit = digits[source[pos.*]];
        if (digit == 0xff) return 0;
        pos.* += 1;
        value |= @as(u64, @intCast(digit & 31)) << shift;
        if (digit & 32 == 0) break;
        if (shift > 55) return 0;
        shift += 5;
    }
    const magnitude: i64 = @intCast(value >> 1);
    return if (value & 1 == 1) -magnitude else magnitude;
}

// Template chunks are usually short. Filter candidate starts in parallel rather
// than rebuilding a 256-entry search table for every chunk. Bound full comparisons
// so repetitive long chunks still use the standard library's skip-table search.
fn findQuasi(source: []const u8, start: usize, needle: []const u8) ?usize {
    if (start > source.len or needle.len > source.len - start) return null;
    if (needle.len == 0) return start;
    const lanes = std.simd.suggestVectorLength(u8) orelse 1;
    if (comptime lanes > 1) {
        if (needle.len > 1) {
            const last = needle.len - 1;
            const end = source.len - last;
            var i = start;
            var comparisons: usize = 0;
            while (i + lanes <= end) : (i += lanes) {
                const heads: @Vector(lanes, u8) = source[i..][0..lanes].*;
                const tails: @Vector(lanes, u8) = source[i + last ..][0..lanes].*;
                const matches = (heads == @as(@Vector(lanes, u8), @splat(needle[0]))) &
                    (tails == @as(@Vector(lanes, u8), @splat(needle[last])));
                var candidates: @Int(.unsigned, lanes) = @bitCast(matches);
                if (@import("builtin").cpu.arch.endian() == .big) candidates = @bitReverse(candidates);
                while (candidates != 0) {
                    const lane = @ctz(candidates);
                    const at = i + lane;
                    if (std.mem.eql(u8, source[at..][0..needle.len], needle)) return at;
                    comparisons += 1;
                    if (comparisons == 32) return std.mem.indexOfPos(u8, source, at + 1, needle);
                    candidates &= candidates - 1;
                }
            }
            return std.mem.indexOfPos(u8, source, i, needle);
        }
    }
    return std.mem.indexOfPos(u8, source, start, needle);
}

fn normalizeCrlf(allocator: Allocator, raw: []const u8, first: usize) ![]const u8 {
    const out = try allocator.alloc(u8, raw.len);
    var read: usize = 0;
    var written: usize = 0;
    var next: ?usize = first;
    while (next) |at| {
        @memcpy(out[written..][0 .. at - read], raw[read..at]);
        written += at - read;
        out[written] = '\n';
        written += 1;
        read = at + 2;
        next = findQuasi(raw, read, "\r\n");
    }
    @memcpy(out[written..][0 .. raw.len - read], raw[read..]);
    return out[0 .. written + raw.len - read];
}

pub fn compose(allocator: Allocator, input: []const u8, intermediate: []const u8, final: []const u8, original: []const u8, copies: []const Copy, anchors: []const Anchor, quasis: []const Quasi, expansions: []const Expansion) ![]const u8 {
    var original_index = try SourceIndex.init(allocator, original);
    var final_index = try SourceIndex.init(allocator, final);
    const intermediate_index = try SourceIndex.initWithLines(allocator, intermediate, false);
    const anchor_index = try AnchorIndex.init(allocator, anchors);
    var copy_index: CopyIndex = .{ .copies = copies };
    var starts: std.ArrayList(u32) = .empty;
    try starts.append(allocator, 0);
    var start: usize = 0;
    while (start < intermediate.len) {
        const length = utf.lineBreakLen(intermediate, start);
        start += if (length > 0) length else text.cpLen(intermediate, start);
        if (length > 0) try starts.append(allocator, @intCast(start));
    }
    var points: std.ArrayList(Point) = .empty;
    try points.ensureTotalCapacity(allocator, input.len / 4 + copies.len);
    var p: usize = 0;
    var gen_line: u32 = 0;
    var gen_column: i64 = 0;
    var orig_line: i64 = 0;
    var orig_column: i64 = 0;
    while (p < input.len) {
        if (input[p] == ';') {
            p += 1;
            gen_line += 1;
            gen_column = 0;
            continue;
        }
        if (input[p] == ',') {
            p += 1;
            continue;
        }
        gen_column += decode(input, &p);
        if (p == input.len or input[p] == ',' or input[p] == ';') continue;
        _ = decode(input, &p);
        orig_line += decode(input, &p);
        orig_column += decode(input, &p);
        if (p < input.len and input[p] != ',' and input[p] != ';') _ = decode(input, &p);
        if (orig_line < 0 or orig_column < 0 or orig_line >= starts.items.len) continue;
        const offset = intermediate_index.advance(starts.items[@intCast(orig_line)], @intCast(orig_column));
        var mapped: ?u32 = null;
        if (copy_index.find(offset)) |item| {
            if (item.length > 0 and offset <= @as(usize, item.generated) + item.length) {
                const source_offset = item.original + @as(u32, @intCast(offset - item.generated));
                mapped = anchorOffset(original, source_offset, item.original, anchor_index);
            } else if (item.length == 0) mapped = item.original;
        }
        const source_offset = mapped orelse continue;
        var column = gen_column;
        for (expansions) |expansion| {
            if (expansion.at.line == gen_line and expansion.at.column <= gen_column) column += expansion.columns;
        }
        try points.append(allocator, .{ .generated = .{ .line = gen_line, .column = @intCast(column) }, .original = original_index.position(source_offset) });
    }
    const main_end = points.items.len;
    var cursor: usize = 0;
    for (quasis) |quasi| {
        const raw = intermediate[quasi.start..quasi.end];
        if (raw.len == 0) continue;
        const crlf = findQuasi(raw, 0, "\r\n");
        const has_crlf = crlf != null;
        const normalized = if (crlf) |first| try normalizeCrlf(allocator, raw, first) else raw;
        const at = findQuasi(final, cursor, normalized) orelse continue;
        var low: usize = 0;
        var high = copies.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            if (copies[mid].generated < quasi.start) low = mid + 1 else high = mid;
        }
        var prefix_end: usize = quasi.start;
        var removed: usize = 0;
        for (copies[low..]) |item| {
            if (item.generated > quasi.end) break;
            if (item.length != 0) continue;
            while (has_crlf and prefix_end < item.generated) : (prefix_end += 1) {
                if (intermediate[prefix_end] == '\n' and prefix_end > quasi.start and intermediate[prefix_end - 1] == '\r') removed += 1;
            }
            const delta = item.generated - quasi.start - removed;
            try points.append(allocator, .{ .generated = final_index.position(at + delta), .original = original_index.position(item.original) });
        }
        cursor = at + normalized.len;
    }
    // Both the codegen mappings and template additions are already ordered.
    // Merge them while encoding, retaining the original mapping on ties.
    var check: usize = 1;
    while (check < main_end) : (check += 1) std.debug.assert(!lessThan({}, points.items[check], points.items[check - 1]));
    check = main_end + 1;
    while (check < points.items.len) : (check += 1) std.debug.assert(!lessThan({}, points.items[check], points.items[check - 1]));
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(allocator, input.len);
    var line: u32 = 0;
    var prev_generated: i64 = 0;
    var prev_line: i64 = 0;
    var prev_column: i64 = 0;
    var previous: ?Position = null;
    var has_segment = false;
    var main: usize = 0;
    var extra = main_end;
    while (main < main_end or extra < points.items.len) {
        var point: Point = undefined;
        if (extra == points.items.len or (main < main_end and !lessThan({}, points.items[extra], points.items[main]))) {
            point = points.items[main];
            main += 1;
        } else {
            point = points.items[extra];
            extra += 1;
        }
        if (previous) |prev| if (prev.line == point.generated.line and prev.column == point.generated.column) continue;
        previous = point.generated;
        while (line < point.generated.line) : (line += 1) {
            try out.append(allocator, ';');
            prev_generated = 0;
            has_segment = false;
        }
        // Four VLQ fields from 32-bit coordinates plus the separator fit in 32 bytes.
        try out.ensureUnusedCapacity(allocator, 32);
        if (has_segment) out.appendAssumeCapacity(',');
        vlq(&out, @as(i64, point.generated.column) - prev_generated);
        vlq(&out, 0);
        vlq(&out, @as(i64, point.original.line) - prev_line);
        vlq(&out, @as(i64, point.original.column) - prev_column);
        prev_generated = point.generated.column;
        prev_line = point.original.line;
        prev_column = point.original.column;
        has_segment = true;
    }
    return out.items;
}

fn lessThan(_: void, a: Point, b: Point) bool {
    return a.generated.line < b.generated.line or (a.generated.line == b.generated.line and a.generated.column < b.generated.column);
}
fn anchorOffset(source: []const u8, offset: u32, fallback: u32, index: AnchorIndex) u32 {
    if (index.find(offset)) |anchor| {
        if (!anchor.multiline) return anchor.point;
        var line_start = offset;
        while (line_start > anchor.point and source[line_start - 1] != '\n' and source[line_start - 1] != '\r') line_start -= 1;
        if (line_start <= anchor.point) return anchor.point;
        while (line_start < source.len and (source[line_start] == ' ' or source[line_start] == '\t')) line_start += 1;
        return line_start;
    }
    return fallback;
}

test "template search and CRLF normalization match the standard library" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const sources = [_][]const u8{
        "",
        "<div>\r\n  🦊 日本語\r</div>\r\n",
        "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab",
        "abababababababababababababababababababababababababababababababababababab",
        "abcde\r\nabcde\r\nabcde\r\nabcde\r\nabcde\r\nabcde\r\nabcde\r\nabcde\r\n",
    };
    for (sources) |source| {
        for (sources) |needle| for (0..source.len + 1) |start| {
            try std.testing.expectEqual(std.mem.indexOfPos(u8, source, start, needle), findQuasi(source, start, needle));
        };
        for (0..source.len + 1) |start| for (start..source.len + 1) |end| {
            const needle = source[start..end];
            try std.testing.expectEqual(std.mem.indexOf(u8, source, needle), findQuasi(source, 0, needle));
        };
        const expected = try std.mem.replaceOwned(u8, arena.allocator(), source, "\r\n", "\n");
        const actual = if (findQuasi(source, 0, "\r\n")) |first| try normalizeCrlf(arena.allocator(), source, first) else source;
        try std.testing.expectEqualStrings(expected, actual);
    }
}

test "copy lookup preserves last duplicate and reordered mapping queries" {
    const copies = [_]Copy{
        .{ .generated = 4, .original = 10, .length = 2 },
        .{ .generated = 8, .original = 20, .length = 0 },
        .{ .generated = 8, .original = 30, .length = 3 },
        .{ .generated = 15, .original = 40, .length = 2 },
    };
    for (0..copies.len + 1) |length| {
        var index: CopyIndex = .{ .copies = copies[0..length] };
        for (0..64) |query| {
            const offset: u32 = @intCast((query * 13) % 23);
            var expected: ?Copy = null;
            for (copies[0..length]) |item| if (item.generated <= offset) {
                expected = item;
            };
            try std.testing.expectEqual(expected, index.find(offset));
        }
    }
}

test "anchor index preserves last-match precedence for overlapping and reordered ranges" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const anchors = [_]Anchor{
        .{ .start = 0, .end = 100, .point = 1 },
        .{ .start = 70, .end = 90, .point = 2 },
        .{ .start = 5, .end = 15, .point = 3 },
        .{ .start = 10, .end = 80, .point = 4 },
        .{ .start = 42, .end = 42, .point = 5 },
    };
    for (0..anchors.len + 1) |length| {
        const index = try AnchorIndex.init(arena.allocator(), anchors[0..length]);
        for (0..102) |offset| {
            var expected: ?Anchor = null;
            for (anchors[0..length]) |anchor| if (offset >= anchor.start and offset <= anchor.end) {
                expected = anchor;
            };
            try std.testing.expectEqual(expected, index.find(@intCast(offset)));
        }
    }
}

test "indexed source positions preserve CRLF and partial UTF-8 boundaries" {
    const sources = [_][]const u8{
        "",
        "plain ASCII",
        "a\r\nb\rc\n\r\n",
        "🦊日本語\r\né e\u{0301}\r\nlast🦊",
        "\xed\xa0\x80\n\xf0\x9f\xa6\x8a\r\n",
    };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for (sources) |source| {
        var index = try SourceIndex.init(arena.allocator(), source);
        for (0..source.len + 1) |end| {
            try std.testing.expectEqual(lineCol(source, end), index.position(end));
        }
        var end = source.len;
        while (end > 0) {
            end -= 1;
            try std.testing.expectEqual(lineCol(source, end), index.position(end));
        }
    }
}

test "indexed UTF-16 columns resolve without rescanning long lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const long: [8192]u8 = @splat('a');
    const source = try std.mem.concat(allocator, u8, &.{
        "🦊é日本語\r\n",
        &long,
        "🦊é日本語\r\n\xed\xa0\x80last",
    });
    const index = try SourceIndex.init(allocator, source);
    const offsets = try SourceIndex.initWithLines(allocator, source, false);
    for (index.lines) |line| {
        var offset: usize = line.start;
        var units: u32 = 0;
        try std.testing.expectEqual(line.start, index.advance(line.start, 0));
        while (offset < source.len) {
            const width: u32 = if (text.cpAt(source, offset) > 0xffff) 2 else 1;
            offset += text.cpLen(source, offset);
            for (1..width + 1) |column| {
                try std.testing.expectEqual(@as(u32, @intCast(offset)), index.advance(line.start, units + @as(u32, @intCast(column))));
                try std.testing.expectEqual(@as(u32, @intCast(offset)), offsets.advance(line.start, units + @as(u32, @intCast(column))));
            }
            units += width;
        }
        try std.testing.expectEqual(@as(u32, @intCast(source.len)), index.advance(line.start, units + 100));
    }
}
