const std = @import("std");
const data = @import("tsx_data.zig");
const unicode = @import("util").UnicodeId;
const Allocator = std.mem.Allocator;
pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
pub fn in(value: []const u8, values: []const []const u8) bool {
    for (values) |v| if (eql(value, v)) return true;
    return false;
}
pub fn cpAt(value: []const u8, i: usize) u21 {
    const n = std.unicode.utf8ByteSequenceLength(value[i]) catch return value[i];
    return std.unicode.utf8Decode(value[i..@min(i + n, value.len)]) catch value[i];
}
pub fn cpLen(value: []const u8, i: usize) usize {
    return @min(std.unicode.utf8ByteSequenceLength(value[i]) catch 1, value.len - i);
}
pub fn whitespace(cp: u21) bool {
    return switch (cp) {
        9...13, 32, 0xa0, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000, 0xfeff => true,
        else => false,
    };
}
pub fn trim(value: []const u8) []const u8 {
    var begin: usize = 0;
    while (begin < value.len) {
        const c = value[begin];
        if (c < 0x80) {
            if (!whitespace(c)) break;
            begin += 1;
        } else {
            if (!whitespace(cpAt(value, begin))) break;
            begin += cpLen(value, begin);
        }
    }
    var end = value.len;
    while (end > begin) {
        const c = value[end - 1];
        if (c < 0x80) {
            if (!whitespace(c)) break;
            end -= 1;
        } else {
            var start = end - 1;
            while (start > begin and value[start] & 0xc0 == 0x80) start -= 1;
            if (!whitespace(cpAt(value, start))) break;
            end = start;
        }
    }
    return value[begin..end];
}

test "trim retains Unicode and WTF-8 content while removing only edge whitespace" {
    const cases = [_]struct { input: []const u8, expected: []const u8 }{
        .{ .input = "", .expected = "" },
        .{ .input = " \t\r\n", .expected = "" },
        .{ .input = "  🦊日本語 é e\u{0301} \r\n", .expected = "🦊日本語 é e\u{0301}" },
        .{ .input = "\u{feff}\u{2003}text\u{2028}\u{3000}", .expected = "text" },
        .{ .input = "\u{200b}text\u{200b}", .expected = "\u{200b}text\u{200b}" },
        .{ .input = " \xed\xa0\x80\n", .expected = "\xed\xa0\x80" },
        .{ .input = "a \n b", .expected = "a \n b" },
        .{ .input = "\x00text\x00", .expected = "\x00text\x00" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(case.expected, trim(case.input));
}
pub fn lower(allocator: Allocator, value: []const u8) ![]const u8 {
    return casing(allocator, value, false);
}
fn caseInfo(cp: u21) ?data.Case {
    var lo: usize = 0;
    var hi: usize = data.cases.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (data.cases[mid].cp < cp) lo = mid + 1 else hi = mid;
    }
    if (lo < data.cases.len and data.cases[lo].cp == cp) return data.cases[lo];
    return null;
}
fn caseValue(cp: u21, upper: bool) ?[]const u8 {
    const info = caseInfo(cp) orelse return null;
    return if (upper) info.upper else info.lower;
}
fn casing(allocator: Allocator, value: []const u8, upper: bool) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < value.len) {
        const end = i + cpLen(value, i);
        try result.appendSlice(allocator, caseValue(cpAt(value, i), upper) orelse value[i..end]);
        i = end;
    }
    return result.items;
}
fn word(cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = data.word_ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (data.word_ranges[mid][1] < cp) lo = mid + 1 else hi = mid;
    }
    return lo < data.word_ranges.len and cp >= data.word_ranges[lo][0];
}
fn idStart(cp: u21) bool {
    return cp == '$' or cp == '_' or (cp < 128 and std.ascii.isAlphabetic(@intCast(cp))) or (cp >= 128 and unicode.canStartId(cp));
}
fn idContinue(cp: u21) bool {
    return idStart(cp) or (cp < 128 and std.ascii.isDigit(@intCast(cp))) or cp == 0x200c or cp == 0x200d or (cp >= 128 and unicode.canContinueId(cp));
}
pub fn jsxName(value: []const u8) bool {
    var i: usize = 0;
    var parts: usize = 1;
    var first = true;
    while (i < value.len) {
        const cp = cpAt(value, i);
        if (cp == ':') {
            if (first or parts == 2) return false;
            parts += 1;
            first = true;
        } else {
            if (first) {
                if (!idStart(cp)) return false;
            } else if (cp != '-' and !idContinue(cp)) return false;
            first = false;
        }
        i += cpLen(value, i);
    }
    return !first;
}
fn identifier(value: []const u8) bool {
    return jsxName(value) and std.mem.indexOfAny(u8, value, ":-") == null;
}
pub const Names = struct { component: []const u8 = "AstroComponent", alias: ?[]const u8 = null };
/// Pascal conversion follows biome_string_case::Case::Pascal (MIT):
/// https://github.com/biomejs/biome/blob/main/crates/biome_string_case/src/lib.rs
/// Copyright (c) 2023-present Biome Developers and Contributors.
/// Copyright (c) 2020-2023 Rome Tools is Rome Tools, Inc. and its affiliates.
/// Permission and warranty terms are reproduced in LICENSE.
fn pascalComponentName(allocator: Allocator, value: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var boundary = true;
    var i: usize = 0;
    while (i < value.len) {
        const cp = cpAt(value, i);
        const end = i + cpLen(value, i);
        if (!word(cp)) {
            boundary = true;
            i = end;
            continue;
        }
        const current = caseInfo(cp);
        const next = if (end < value.len) caseInfo(cpAt(value, end)) else null;
        const uppercase = if (current) |info| info.uppercase else false;
        const lowercase = if (current) |info| info.lowercase else false;
        const next_lowercase = if (next) |info| info.lowercase else false;
        const next_uppercase = if (next) |info| info.uppercase else false;
        if (i != 0 and uppercase and next_lowercase) boundary = true;
        try result.appendSlice(allocator, caseValue(cp, boundary) orelse value[i..end]);
        boundary = lowercase and next_uppercase;
        i = end;
    }
    return result.items;
}
pub fn componentNames(allocator: Allocator, filename: ?[]const u8) !Names {
    const filename_value = filename orelse return .{};
    if (filename_value.len == 0 or eql(filename_value, "<stdin>")) return .{};
    const last = if (std.mem.lastIndexOfAny(u8, filename_value, "/\\")) |i| filename_value[i + 1 ..] else filename_value;
    const base = if (std.mem.lastIndexOfScalar(u8, last, '.')) |i| last[0..i] else last;
    if (eql(base, "404")) return .{ .component = "FourOhFourAstroComponent" };
    const first = last[0 .. std.mem.indexOfScalar(u8, last, '.') orelse last.len];
    const pascal = try pascalComponentName(allocator, first);
    if (!identifier(pascal)) return .{};
    if (std.mem.startsWith(u8, base, "[") and std.mem.endsWith(u8, base, "]")) return .{ .component = try std.fmt.allocPrint(allocator, "_{s}_AstroComponent", .{pascal}) };
    var filtered: std.ArrayList(u8) = .empty;
    for (base) |c| if (std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c == '-') {
        try filtered.append(allocator, c);
    };
    var letter: ?usize = null;
    for (filtered.items, 0..) |c, j| if (std.ascii.isAlphabetic(c)) {
        letter = j;
        break;
    };
    var clean: std.ArrayList(u8) = .empty;
    if (letter == null) try clean.append(allocator, 'A');
    var words = std.mem.tokenizeAny(u8, filtered.items[letter orelse 0 ..], "-_");
    var word_index: usize = 0;
    while (words.next()) |part| {
        var dollar_free: std.ArrayList(u8) = .empty;
        for (part) |c| if (c != '$') {
            try dollar_free.append(allocator, c);
        };
        if (dollar_free.items.len > 0) {
            try clean.append(allocator, std.ascii.toUpper(dollar_free.items[0]));
            for (dollar_free.items[1..]) |c| try clean.append(allocator, if (word_index == 0) c else std.ascii.toLower(c));
        }
        word_index += 1;
    }
    return .{ .component = try std.fmt.allocPrint(allocator, "{s}AstroComponent", .{pascal}), .alias = if (eql(pascal, clean.items)) pascal else null };
}
pub fn decodeEntities(allocator: Allocator, value: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    var cursor: usize = 0;
    while (cursor < value.len) {
        if (value[cursor] != '&') {
            try result.append(allocator, value[cursor]);
            cursor += 1;
            continue;
        }
        var end = cursor + 1;
        var replacement: ?[]const u8 = null;
        if (end < value.len and value[end] == '#') {
            end += 1;
            const hex = end < value.len and std.ascii.toLower(value[end]) == 'x';
            if (hex) end += 1;
            const digits = end;
            while (end < value.len and (if (hex) std.ascii.isHex(value[end]) else std.ascii.isDigit(value[end]))) end += 1;
            if (end > digits) {
                const code = std.fmt.parseInt(u32, value[digits..end], if (hex) 16 else 10) catch 0x110000;
                const controls = [_]u21{ 8364, 129, 8218, 402, 8222, 8230, 8224, 8225, 710, 8240, 352, 8249, 338, 141, 381, 143, 144, 8216, 8217, 8220, 8221, 8226, 8211, 8212, 732, 8482, 353, 8250, 339, 157, 382, 376 };
                const cp: u21 = if (code == 0 or code > 0x10ffff or code >= 0xd800 and code <= 0xdfff) 0xfffd else if (code >= 128 and code <= 159) controls[code - 128] else @intCast(code);
                const bytes = try allocator.alloc(u8, 4);
                const n = std.unicode.utf8Encode(cp, bytes[0..4]) catch unreachable;
                replacement = bytes[0..n];
                if (end < value.len and value[end] == ';') end += 1;
            }
        } else if (end < value.len and std.ascii.isAlphabetic(value[end])) {
            while (end < value.len and std.ascii.isAlphanumeric(value[end])) end += 1;
            if (end < value.len and value[end] == ';') end += 1;
            var prefix_end = end;
            while (prefix_end > cursor + 1) : (prefix_end -= 1) {
                if (data.entities.get(value[cursor..prefix_end])) |entity| {
                    if (value[prefix_end - 1] != ';' and prefix_end < value.len and (value[prefix_end] == '=' or std.ascii.isAlphanumeric(value[prefix_end]))) break;
                    replacement = try std.mem.concat(allocator, u8, &.{ entity, value[prefix_end..end] });
                    break;
                }
            }
        }
        if (replacement) |text| {
            try result.appendSlice(allocator, text);
            cursor = end;
        } else {
            try result.append(allocator, '&');
            cursor += 1;
        }
    }
    return result.items;
}
