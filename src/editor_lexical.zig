const std = @import("std");

// Ported from biome_html_parser's JsScanner at b7d903781c7968517675de39d3f086184d83faf7.
// Copyright (c) 2023-present Biome Developers and Contributors.
// Copyright (c) 2020-2023 Rome Tools is Rome Tools, Inc. and its affiliates.
// MIT permission and warranty terms are reproduced in LICENSE.
// This only finds host-language delimiters; Yuku builds the JavaScript AST.
const Tag = struct { closing: bool, name: usize, unquoted: bool = false };
const Frame = union(enum) { code: u8, template, tag: Tag, arguments, children };
const Stop = enum { expression, frontmatter };
const Scanner = struct {
    source: []const u8,
    position: usize = 0,
    frames: [256]Frame = undefined,
    depth: usize = 0,
    jsx: bool,
    entered_jsx: bool = false,

    fn push(self: *Scanner, frame: Frame) void {
        if (self.depth == self.frames.len) {
            self.position = self.source.len;
            return;
        }
        self.frames[self.depth] = frame;
        self.depth += 1;
    }
    fn at(self: *const Scanner, offset: usize, byte: u8) bool {
        return self.position + offset < self.source.len and self.source[self.position + offset] == byte;
    }
    fn advance(self: *Scanner, count: usize) void {
        self.position = @min(self.position + count, self.source.len);
    }
    fn string(self: *Scanner, quote: u8) void {
        self.advance(1);
        while (self.position < self.source.len) {
            const byte = self.source[self.position];
            self.advance(1);
            if (byte == '\\') self.advance(1) else if (byte == quote) break;
        }
    }
    fn slash(self: *Scanner) void {
        if (self.at(1, '/')) {
            self.advance(2);
            while (self.position < self.source.len) {
                const byte = self.source[self.position];
                self.advance(1);
                if (byte == '\n') break;
            }
        } else if (self.at(1, '*')) {
            self.advance(2);
            while (self.position < self.source.len) {
                if (self.at(0, '*') and self.at(1, '/')) {
                    self.advance(2);
                    break;
                }
                self.advance(1);
            }
        } else if (self.at(1, '>') and !operandStart(self.source[0..self.position])) {
            self.advance(1);
        } else if ((self.position == 0 or self.source[self.position - 1] != '<') and regexStart(self.source[0..self.position])) {
            self.advance(1);
            var character_class = false;
            while (self.position < self.source.len) {
                const byte = self.source[self.position];
                self.advance(1);
                if (byte == '\\') self.advance(1) else if (byte == '[') character_class = true else if (byte == ']') character_class = false else if (byte == '/' and !character_class) break;
            }
        } else self.advance(1);
    }
    fn tagName(self: *const Scanner, start: usize) []const u8 {
        var end = start;
        while (end < self.source.len and tagByte(self.source[end])) : (end += 1) {}
        return self.source[start..end];
    }
    fn run(self: *Scanner, stop: Stop) usize {
        while (self.position < self.source.len) {
            const byte = self.source[self.position];
            const frame: Frame = if (self.depth == 0) .{ .code = 0 } else self.frames[self.depth - 1];
            switch (frame) {
                .code => |close| switch (byte) {
                    '\'', '"' => self.string(byte),
                    '`' => {
                        self.push(.template);
                        self.advance(1);
                    },
                    '/' => self.slash(),
                    '{' => {
                        self.push(.{ .code = '}' });
                        self.advance(1);
                    },
                    '}', ']' => {
                        if (self.depth > 0 and close == byte) self.depth -= 1 else if (self.depth == 0 and stop == .expression and byte == '}') return self.position;
                        self.advance(1);
                    },
                    '-' => {
                        if (stop == .frontmatter and self.depth == 0 and std.mem.startsWith(u8, self.source[self.position..], "---")) return self.position;
                        self.advance(1);
                    },
                    '<' => {
                        if (self.jsx and self.position + 1 < self.source.len and startsTag(self.source[self.position + 1]) and expressionStart(self.source[0..self.position])) {
                            self.entered_jsx = true;
                            self.push(.{ .tag = .{ .closing = false, .name = self.position + 1 } });
                        }
                        self.advance(1);
                    },
                    else => self.advance(1),
                },
                .template => switch (byte) {
                    '\\' => self.advance(2),
                    '`' => {
                        self.depth -= 1;
                        self.advance(1);
                    },
                    '$' => {
                        if (self.at(1, '{')) {
                            self.push(.{ .code = '}' });
                            self.advance(2);
                        } else self.advance(1);
                    },
                    else => self.advance(1),
                },
                .tag => |tag| switch (byte) {
                    '\'', '"' => self.string(byte),
                    '`' => {
                        self.push(.template);
                        self.advance(1);
                    },
                    '{' => {
                        self.push(.{ .code = '}' });
                        self.advance(1);
                    },
                    '=' => {
                        const next = if (self.position + 1 < self.source.len) self.source[self.position + 1] else 0;
                        self.frames[self.depth - 1].tag.unquoted = next != 0 and !std.ascii.isWhitespace(next) and std.mem.indexOfScalar(u8, "\"'`{", next) == null;
                        self.advance(1);
                    },
                    '>' => {
                        self.depth -= 1;
                        const scanned = trimEnd(self.source[0..self.position]);
                        const self_closing = !tag.unquoted and scanned.len > 0 and scanned[scanned.len - 1] == '/';
                        if (!tag.closing and !self_closing and !voidTag(self.tagName(tag.name))) self.push(.children);
                        self.advance(1);
                    },
                    ',' => {
                        self.depth -= 1;
                        self.advance(1);
                    },
                    '<' => {
                        self.push(.arguments);
                        self.advance(1);
                    },
                    else => {
                        if (tag.unquoted and std.ascii.isWhitespace(byte)) self.frames[self.depth - 1].tag.unquoted = false;
                        self.advance(1);
                    },
                },
                .arguments => switch (byte) {
                    '\'', '"' => self.string(byte),
                    '`' => {
                        self.push(.template);
                        self.advance(1);
                    },
                    '<' => {
                        self.push(.arguments);
                        self.advance(1);
                    },
                    '=' => self.advance(if (self.at(1, '>')) 2 else 1),
                    '>' => {
                        self.depth -= 1;
                        self.advance(1);
                    },
                    else => self.advance(1),
                },
                .children => switch (byte) {
                    '{' => {
                        self.push(.{ .code = '}' });
                        self.advance(1);
                    },
                    '<' => {
                        if (self.at(1, '/')) {
                            self.depth -= 1;
                            self.push(.{ .tag = .{ .closing = true, .name = self.position + 2 } });
                            self.advance(2);
                        } else if (self.position + 1 < self.source.len and startsTag(self.source[self.position + 1])) {
                            self.push(.{ .tag = .{ .closing = false, .name = self.position + 1 } });
                            self.advance(1);
                        } else self.advance(1);
                    },
                    else => self.advance(1),
                },
            }
        }
        return self.position;
    }
};
fn trimEnd(source: []const u8) []const u8 {
    return std.mem.trimEnd(u8, source, " \t\r\n\x0b\x0c");
}
fn word(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '$';
}
fn keyword(source: []const u8) bool {
    var start = source.len;
    while (start > 0 and word(source[start - 1])) : (start -= 1) {}
    const previous = trimEnd(source[0..start]);
    if (previous.len > 0 and (previous[previous.len - 1] == '.' or previous[previous.len - 1] == '#')) return false;
    const name = source[start..];
    inline for (.{ "await", "case", "delete", "do", "else", "in", "instanceof", "new", "return", "throw", "typeof", "void", "yield" }) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}
fn expressionStart(source: []const u8) bool {
    const scanned = trimEnd(source);
    if (scanned.len == 0) return true;
    const byte = scanned[scanned.len - 1];
    if (word(byte)) return keyword(scanned);
    return std.mem.indexOfScalar(u8, ")]\"'`", byte) == null;
}
fn regexStart(source: []const u8) bool {
    const scanned = trimEnd(source);
    if (scanned.len == 0) return true;
    const byte = scanned[scanned.len - 1];
    if (std.ascii.isAlphabetic(byte) or byte == '_') return keyword(scanned);
    return !std.ascii.isDigit(byte) and std.mem.indexOfScalar(u8, "$)]+-", byte) == null;
}
fn operandStart(source: []const u8) bool {
    const scanned = trimEnd(source);
    if (scanned.len == 0) return true;
    const byte = scanned[scanned.len - 1];
    if (byte == '>') return scanned.len > 1 and scanned[scanned.len - 2] == '=';
    return std.mem.indexOfScalar(u8, "(,=:[!&|?;{~^%*", byte) != null or (std.ascii.isAlphabetic(byte) and keyword(scanned));
}
fn tagByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':';
}
fn startsTag(byte: u8) bool {
    return byte == '>' or byte == '_' or std.ascii.isAlphabetic(byte);
}
fn voidTag(name: []const u8) bool {
    inline for (.{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr" }) |value| if (std.mem.eql(u8, name, value)) return true;
    return false;
}
pub fn expressionEnd(source: []const u8, start: usize, limit: usize) usize {
    var scanner: Scanner = .{ .source = source[start..limit], .jsx = true };
    var end = scanner.run(.expression);
    if (end == scanner.source.len and scanner.entered_jsx) {
        scanner.position = 0;
        scanner.depth = 0;
        scanner.jsx = false;
        end = scanner.run(.expression);
    }
    return start + end;
}
pub fn frontmatterEnd(source: []const u8, start: usize) ?usize {
    var scanner: Scanner = .{ .source = source[start..], .jsx = false };
    const end = scanner.run(.frontmatter);
    return if (end < scanner.source.len) start + end else null;
}
