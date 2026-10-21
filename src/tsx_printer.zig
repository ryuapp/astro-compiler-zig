const std = @import("std");
const Allocator = std.mem.Allocator;
pub const Range = struct { start: u32, end: u32 };
pub const Script = struct { position: Range, content: []const u8, type: []const u8 };
pub const Style = struct { position: Range, content: []const u8, type: []const u8, lang: []const u8 };
pub const Diagnostic = struct { message: []const u8, severity: u32, position: Range };
const Run = struct { generated: u32, original: ?u32 };
pub const Mode = enum { jsx, template, comment, attribute, string };
pub const Error = error{ OutOfMemory, SourceTooLarge };

pub fn utf16Length(text: []const u8) u32 {
    var count: u32 = 0;
    for (text) |c| if (c & 0xc0 != 0x80) {
        count += if (c >= 0xf0) @as(u32, 2) else 1;
    };
    return count;
}

pub const Printer = struct {
    allocator: Allocator,
    source: []const u8,
    offsets: []u32,
    code: std.ArrayList(u8) = .empty,
    length: u32 = 0,
    runs: std.ArrayList(Run) = .empty,
    scripts: std.ArrayList(Script) = .empty,
    styles: std.ArrayList(Style) = .empty,
    script_ranges: std.ArrayList(Range) = .empty,
    style_ranges: std.ArrayList(Range) = .empty,

    pub fn init(allocator: Allocator, source: []const u8) !Printer {
        const offsets = try allocator.alloc(u32, source.len + 1);
        var i: usize = 0;
        var units: u32 = 0;
        while (i < source.len) {
            const n = std.unicode.utf8ByteSequenceLength(source[i]) catch 1;
            const end = @min(i + n, source.len);
            @memset(offsets[i..end], units);
            units += if (n == 4) @as(u32, 2) else 1;
            i = end;
        }
        offsets[source.len] = units;
        return .{ .allocator = allocator, .source = source, .offsets = offsets };
    }
    pub fn position(self: *const Printer, byte: usize) u32 {
        return self.offsets[@min(byte, self.source.len)];
    }
    pub fn range(self: *const Printer, start: usize, end: usize) Range {
        return .{ .start = self.position(start), .end = self.position(end) };
    }
    pub fn write(self: *Printer, value: []const u8, original: ?usize) Error!void {
        if (value.len == 0) return;
        const next: Run = .{ .generated = self.length, .original = if (original) |p| self.position(p) else null };
        if (self.runs.items.len > 0) {
            const last = &self.runs.items[self.runs.items.len - 1];
            if (last.generated == next.generated) last.* = next else {
                const same = if (last.original) |a| if (next.original) |b| @as(i64, b) - a == @as(i64, next.generated) - last.generated else false else next.original == null;
                if (!same) try self.runs.append(self.allocator, next);
            }
        } else try self.runs.append(self.allocator, next);
        try self.code.appendSlice(self.allocator, value);
        self.length = std.math.add(u32, self.length, utf16Length(value)) catch return error.SourceTooLarge;
    }
    pub fn put(self: *Printer, value: []const u8) Error!void {
        try self.write(value, null);
    }
    pub fn copy(self: *Printer, start: usize, end: usize) Error!void {
        const a = @min(start, self.source.len);
        const b = @max(a, @min(end, self.source.len));
        try self.write(self.source[a..b], a);
    }
    pub fn text(self: *Printer, start: usize, end: usize, mode: Mode) Error!void {
        var i = start;
        var previous: u8 = 0;
        while (i < @min(end, self.source.len)) {
            const n = std.unicode.utf8ByteSequenceLength(self.source[i]) catch 1;
            const next = @min(i + n, end);
            const c = self.source[i];
            const replacement: ?[]const u8 = switch (mode) {
                .template => if (c == '\\') "\\\\" else if (c == '`') "\\`" else if (c == '$' and next < end and self.source[next] == '{') "\\$" else null,
                .comment => if (c == '\\') "\\\\" else if (c == '{') "\\\\{" else if (c == '}') "\\\\}" else if (c == '/' and previous == '*') "\\/" else null,
                .attribute => if (c == '"') "&quot;" else null,
                .string => switch (c) {
                    '"' => "\\\"",
                    '\\' => "\\\\",
                    '\n' => "\\n",
                    '\r' => "\\r",
                    '\t' => "\\t",
                    8 => "\\b",
                    12 => "\\f",
                    else => if (c < 32) try std.fmt.allocPrint(self.allocator, "\\u00{x:0>2}", .{c}) else if (std.mem.eql(u8, self.source[i..next], "\u{2028}")) "\\u2028" else if (std.mem.eql(u8, self.source[i..next], "\u{2029}")) "\\u2029" else null,
                },
                .jsx => null,
            };
            if (mode == .jsx and std.mem.indexOfScalar(u8, "<>{}", c) != null) {
                try self.put("{`");
                try self.write(self.source[i..next], i);
                try self.put("`}");
            } else try self.write(replacement orelse self.source[i..next], if (replacement == null) i else null);
            previous = c;
            i = next;
        }
    }
    pub fn quoted(self: *Printer, start: usize, end: usize) !void {
        try self.put("\"");
        try self.text(start, end, .string);
        try self.put("\"");
    }
    /// Decoded HTML attribute values have no verbatim source mapping.
    pub fn stringValue(self: *Printer, value: []const u8) Error!void {
        const encoded = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        var cursor: usize = 0;
        var i: usize = 0;
        while (i < encoded.len) : (i += 1) {
            const replacement: ?[]const u8 = if (std.mem.startsWith(u8, encoded[i..], "\u{2028}")) "\\u2028" else if (std.mem.startsWith(u8, encoded[i..], "\u{2029}")) "\\u2029" else null;
            if (replacement) |escaped| {
                try self.put(encoded[cursor..i]);
                try self.put(escaped);
                i += 2;
                cursor = i + 1;
            }
        }
        try self.put(encoded[cursor..]);
    }
    pub fn mappings(self: *Printer, extra: []const []const u32) ![]const []const u32 {
        var result: std.ArrayList([]const u32) = .empty;
        try result.appendSlice(self.allocator, extra);
        for (self.runs.items, 0..) |run, i| {
            const original = run.original orelse continue;
            const end = if (i + 1 < self.runs.items.len) self.runs.items[i + 1].generated else self.length;
            const length = @min(end - run.generated, self.offsets[self.source.len] - original);
            if (length > 0) try result.append(self.allocator, try self.allocator.dupe(u32, &.{ run.generated, length, original, length, 0 }));
        }
        std.mem.sort([]const u32, result.items, {}, struct {
            fn less(_: void, a: []const u32, b: []const u32) bool {
                return a[0] < b[0];
            }
        }.less);
        return result.items;
    }
};
