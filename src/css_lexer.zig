const std = @import("std");

pub const Error = error{ OutOfMemory, InvalidCss, CssNestingTooDeep };
pub const Kind = enum { ident, at, hash, function, string, bad_string, url, space, comment, cdo, cdc, open_brace, close_brace, open_paren, close_paren, open_square, close_square, delim };
pub const Token = struct {
    kind: Kind,
    start: usize,
    end: usize,
    pair: usize = 0,
};

pub fn whitespace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn nameByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c >= 0x80;
}

fn escapeEnd(source: []const u8, start: usize) Error!usize {
    var pos = start + 1;
    if (pos == source.len or source[pos] == '\n' or source[pos] == '\r' or source[pos] == 0x0c) return error.InvalidCss;
    if (!std.ascii.isHex(source[pos])) return pos + 1;
    var digits: usize = 0;
    while (pos < source.len and digits < 6 and std.ascii.isHex(source[pos])) : (digits += 1) pos += 1;
    if (pos < source.len and whitespace(source[pos])) {
        if (source[pos] == '\r' and pos + 1 < source.len and source[pos + 1] == '\n') pos += 1;
        pos += 1;
    }
    return pos;
}

fn nameEnd(source: []const u8, start: usize) Error!usize {
    var pos = start;
    while (pos < source.len) {
        if (source[pos] == '\\') {
            if (!validEscape(source, pos)) break;
            pos = try escapeEnd(source, pos);
        } else if (nameByte(source[pos])) {
            pos += 1;
        } else break;
    }
    return pos;
}

fn validEscape(source: []const u8, start: usize) bool {
    return start + 1 < source.len and source[start + 1] != '\n' and source[start + 1] != '\r' and source[start + 1] != 0x0c;
}

fn startsName(source: []const u8, start: usize) bool {
    if (start >= source.len) return false;
    const c = source[start];
    if (std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80) return true;
    if (c == '\\') return validEscape(source, start);
    return c == '-' and start + 1 < source.len and (nameByte(source[start + 1]) or source[start + 1] == '\\') and !std.ascii.isDigit(source[start + 1]);
}

pub fn nameIs(source: []const u8, token: Token, expected: []const u8) bool {
    return nameMatches(source, token, expected, false, false);
}

pub fn nameIsExact(source: []const u8, token: Token, expected: []const u8) bool {
    return nameMatches(source, token, expected, false, true);
}

pub fn nameStartsWith(source: []const u8, token: Token, expected: []const u8) bool {
    return nameMatches(source, token, expected, true, false);
}

fn nameMatches(source: []const u8, token: Token, expected: []const u8, prefix: bool, case_sensitive: bool) bool {
    var pos = token.start + @intFromBool(token.kind == .at or token.kind == .hash);
    const end = token.end - @intFromBool(token.kind == .function);
    var index: usize = 0;
    while (pos < end) {
        var cp: u32 = source[pos];
        pos += 1;
        if (cp == '\\') {
            if (pos == end) return false;
            if (std.ascii.isHex(source[pos])) {
                cp = 0;
                var count: usize = 0;
                while (pos < end and count < 6 and std.ascii.isHex(source[pos])) : (count += 1) {
                    cp = cp * 16 + (std.fmt.charToDigit(source[pos], 16) catch unreachable);
                    pos += 1;
                }
                if (pos < end and whitespace(source[pos])) {
                    if (source[pos] == '\r' and pos + 1 < end and source[pos + 1] == '\n') pos += 1;
                    pos += 1;
                }
            } else {
                cp = source[pos];
                pos += 1;
            }
        }
        if (index == expected.len) return prefix;
        if (cp > 0x7f) return false;
        const byte: u8 = @intCast(cp);
        if ((if (case_sensitive) byte else std.ascii.toLower(byte)) != expected[index]) return false;
        index += 1;
    }
    return index == expected.len;
}

/// CSS component tokens retain original byte spans. Matched blocks let callers
/// skip arbitrary declaration values without interpreting or serializing them.
pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) Error![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var stack: [256]usize = undefined;
    var depth: usize = 0;
    var pos: usize = 0;
    while (pos < source.len) {
        const start = pos;
        const c = source[pos];
        var kind: Kind = .delim;
        pos += 1;
        if (std.mem.startsWith(u8, source[start..], "<!--")) {
            kind = .cdo;
            pos = start + 4;
        } else if (std.mem.startsWith(u8, source[start..], "-->")) {
            kind = .cdc;
            pos = start + 3;
        } else if (whitespace(c)) {
            kind = .space;
            while (pos < source.len and whitespace(source[pos])) : (pos += 1) {}
        } else if (c == '/' and pos < source.len and source[pos] == '*') {
            kind = .comment;
            pos = if (std.mem.indexOfPos(u8, source, pos + 1, "*/")) |end| end + 2 else source.len;
        } else if (c == '"' or c == '\'') {
            kind = .string;
            while (pos < source.len and source[pos] != c) {
                if (source[pos] == '\\') {
                    pos += 1;
                    if (pos == source.len) break;
                    if (source[pos] == '\r' and pos + 1 < source.len and source[pos + 1] == '\n') pos += 1;
                    pos += 1;
                } else if (source[pos] == '\n' or source[pos] == '\r' or source[pos] == 0x0c) {
                    kind = .bad_string;
                    break;
                } else pos += 1;
            }
            if (pos < source.len and source[pos] == c) pos += 1;
        } else if (startsName(source, start) or ((c == '@' or c == '#') and pos < source.len and (nameByte(source[pos]) or source[pos] == '\\'))) {
            kind = if (c == '@') .at else if (c == '#') .hash else .ident;
            pos = try nameEnd(source, if (kind == .ident) start else pos);
            if (kind == .ident and pos < source.len and source[pos] == '(') {
                pos += 1;
                kind = .function;
                var next = pos;
                while (next < source.len and whitespace(source[next])) : (next += 1) {}
                if (nameIs(source, .{ .kind = .function, .start = start, .end = pos }, "url") and
                    (next == source.len or (source[next] != '"' and source[next] != '\'')))
                {
                    kind = .url;
                    pos = next;
                    while (pos < source.len and source[pos] != ')') {
                        if (source[pos] == '\\' and validEscape(source, pos)) pos = try escapeEnd(source, pos) else pos += 1;
                    }
                    if (pos < source.len) pos += 1;
                }
            }
        } else kind = switch (c) {
            '{' => .open_brace,
            '}' => .close_brace,
            '(' => .open_paren,
            ')' => .close_paren,
            '[' => .open_square,
            ']' => .close_square,
            else => .delim,
        };
        const index = tokens.items.len;
        try tokens.append(allocator, .{ .kind = kind, .start = start, .end = pos });
        switch (kind) {
            .open_brace, .open_paren, .open_square, .function => {
                if (depth == stack.len) return error.CssNestingTooDeep;
                stack[depth] = index;
                depth += 1;
            },
            .close_brace, .close_paren, .close_square => {
                if (depth == 0) continue;
                const opening = stack[depth - 1];
                const expected: Kind = switch (tokens.items[opening].kind) {
                    .open_brace => .close_brace,
                    .open_square => .close_square,
                    else => .close_paren,
                };
                if (kind != expected) continue;
                depth -= 1;
                tokens.items[opening].pair = index;
                tokens.items[index].pair = opening;
            },
            else => {},
        }
    }
    // CSS closes unfinished blocks at EOF. Zero-width closing tokens preserve
    // that structure without adding bytes to the source-preserving output.
    while (depth > 0) {
        depth -= 1;
        const opening = stack[depth];
        const close: Kind = switch (tokens.items[opening].kind) {
            .open_brace => .close_brace,
            .open_square => .close_square,
            else => .close_paren,
        };
        tokens.items[opening].pair = tokens.items.len;
        try tokens.append(allocator, .{ .kind = close, .start = source.len, .end = source.len, .pair = opening });
    }
    return tokens.toOwnedSlice(allocator);
}
