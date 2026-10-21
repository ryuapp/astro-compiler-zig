const std = @import("std");

// Used only for frontmatter fences, quoted attribute boundaries and recovery.
// Valid JavaScript expression boundaries are determined by Yuku's parser.
pub fn quotedEnd(source: []const u8, start: usize, limit: usize) usize {
    return quotedEndDepth(source, start, limit, 0);
}

fn quotedEndDepth(source: []const u8, start: usize, limit: usize, depth: usize) usize {
    if (depth >= 64) return limit;
    const quote = source[start];
    var i = start + 1;
    while (i < limit) {
        if (source[i] == '\\') {
            i = @min(i + 2, limit);
        } else if (source[i] == quote) {
            return i + 1;
        } else if (quote == '`' and source[i] == '$' and i + 1 < limit and source[i + 1] == '{') {
            i = balancedEndDepth(source, i + 2, limit, '}', depth + 1);
        } else {
            i += 1;
        }
    }
    return limit;
}

pub fn regexEnd(source: []const u8, start: usize, limit: usize) usize {
    var i = start + 1;
    var character_class = false;
    while (i < limit) : (i += 1) {
        switch (source[i]) {
            '\\' => i = @min(i + 1, limit - 1),
            '[' => character_class = true,
            ']' => character_class = false,
            '/' => if (!character_class) {
                i += 1;
                while (i < limit and std.ascii.isAlphabetic(source[i])) : (i += 1) {}
                return i;
            },
            '\n', '\r' => return i,
            else => {},
        }
    }
    return limit;
}

pub fn commentEnd(source: []const u8, start: usize, limit: usize) ?usize {
    if (start + 1 >= limit or source[start] != '/') return null;
    if (source[start + 1] == '/') return std.mem.indexOfScalarPos(u8, source[0..limit], start + 2, '\n') orelse limit;
    if (source[start + 1] == '*') return if (std.mem.indexOfPos(u8, source[0..limit], start + 2, "*/")) |end| end + 2 else limit;
    return null;
}

pub fn balancedEnd(source: []const u8, start: usize, limit: usize, close: u8) usize {
    return balancedEndDepth(source, start, limit, close, 0);
}

fn balancedEndDepth(source: []const u8, start: usize, limit: usize, close: u8, depth: usize) usize {
    if (depth >= 64) return limit;
    var i = start;
    var operand = true;
    while (i < limit) {
        const c = source[i];
        if (c == close) return i + 1;
        if (c == '\'' or c == '"' or c == '`') {
            i = quotedEndDepth(source, i, limit, depth + 1);
            operand = false;
        } else if (commentEnd(source, i, limit)) |end| {
            i = end;
        } else if (c == '/' and operand) {
            i = regexEnd(source, i, limit);
            operand = false;
        } else if (c == '{' or c == '(' or c == '[') {
            i = balancedEndDepth(source, i + 1, limit, switch (c) {
                '{' => '}',
                '(' => ')',
                else => ']',
            }, depth + 1);
            operand = false;
        } else if (isIdentifier(c)) {
            const begin = i;
            while (i < limit and isIdentifier(source[i])) : (i += 1) {}
            operand = keywordExpectsOperand(source[begin..i]);
        } else {
            if (!std.ascii.isWhitespace(c)) operand = c != ')' and c != ']' and c != '}' and !std.ascii.isDigit(c);
            i += 1;
        }
    }
    return limit;
}

pub fn frontmatterEnd(source: []const u8, start: usize) ?usize {
    var i = start;
    var operand = true;
    while (i < source.len) {
        if (std.mem.startsWith(u8, source[i..], "---") and
            (i == start or std.ascii.isWhitespace(source[i - 1]))) return i;
        const c = source[i];
        if (c == '\'' or c == '"' or c == '`') {
            i = quotedEnd(source, i, source.len);
            operand = false;
        } else if (commentEnd(source, i, source.len)) |end| {
            i = end;
        } else if (c == '/' and operand) {
            i = regexEnd(source, i, source.len);
            operand = false;
        } else if (isIdentifier(c)) {
            const begin = i;
            while (i < source.len and isIdentifier(source[i])) : (i += 1) {}
            operand = keywordExpectsOperand(source[begin..i]);
        } else {
            if (!std.ascii.isWhitespace(c)) operand = c != ')' and c != ']' and c != '}' and !std.ascii.isDigit(c);
            i += 1;
        }
    }
    return null;
}

pub fn isIdentifier(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$' or c >= 0x80;
}

/// Detect compiler identifier collisions even when the spelling uses JS Unicode
/// escapes. Decoding strings too is conservative and prevents marker replacement
/// from ever touching user-authored string contents after code generation.
pub fn decodedSpelling(allocator: std.mem.Allocator, source: []const u8) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.ensureTotalCapacity(allocator, source.len);
    var cursor: usize = 0;
    while (cursor < source.len) {
        if (source[cursor] == '\\' and cursor + 1 < source.len and (source[cursor + 1] == 'u' or source[cursor + 1] == 'x')) {
            var begin = cursor + 2;
            var end = @min(begin + @as(usize, if (source[cursor + 1] == 'u') 4 else 2), source.len);
            var consumed = end;
            if (begin < source.len and source[begin] == '{' and source[cursor + 1] == 'u') {
                begin += 1;
                end = std.mem.indexOfScalarPos(u8, source, begin, '}') orelse source.len;
                consumed = @min(end + 1, source.len);
            }
            const point = std.fmt.parseInt(u32, source[begin..end], 16) catch std.math.maxInt(u32);
            if (point < 128) {
                try output.append(allocator, @intCast(point));
                cursor = consumed;
                continue;
            }
        }
        try output.append(allocator, source[cursor]);
        cursor += 1;
    }
    return output.toOwnedSlice(allocator);
}

fn keywordExpectsOperand(word: []const u8) bool {
    for ([_][]const u8{ "return", "throw", "case", "delete", "typeof", "void", "new", "in", "of", "yield", "await", "instanceof" }) |keyword| {
        if (std.mem.eql(u8, word, keyword)) return true;
    }
    return false;
}

test "fences in nested templates comments strings and regex are ignored" {
    const source = "const x = `hello\n---\n${`nested ${/---/.source}`}`; /*\n---\n*/\n---\n";
    try std.testing.expectEqual(source.len - 4, frontmatterEnd(source, 0).?);
}
