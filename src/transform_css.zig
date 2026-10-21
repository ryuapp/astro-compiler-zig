const std = @import("std");
const text = @import("tsx_text.zig");
const lex = @import("css_lexer.zig");
const selectors = @import("css_selectors.zig");
const Allocator = std.mem.Allocator;
pub const Strategy = selectors.Strategy;

pub fn shouldScope(name: []const u8) bool {
    for ([_][]const u8{ "Fragment", "base", "font", "frame", "frameset", "head", "link", "meta", "noframes", "noscript", "script", "style", "slot", "title" }) |item| if (text.eql(name, item)) return false;
    return true;
}

/// Rewrite style-rule selectors only. Declaration values, at-rule conditions,
/// comments outside selectors, and their original formatting remain source slices.
pub fn scope(allocator: Allocator, source: []const u8, hash: []const u8, strategy: Strategy) ![]const u8 {
    const tokens = lex.tokenize(allocator, source) catch |err| switch (err) {
        error.InvalidCss => return source,
        else => return err,
    };
    var sheet: Sheet = .{ .allocator = allocator, .source = source, .tokens = tokens, .hash = hash, .strategy = strategy };
    sheet.rules(0, tokens.len, false, 0) catch |err| switch (err) {
        error.InvalidCss => return source,
        else => return err,
    };
    if (sheet.copied == 0) return source;
    try sheet.out.appendSlice(allocator, source[sheet.copied..]);
    return sheet.out.toOwnedSlice(allocator);
}

const Sheet = struct {
    allocator: Allocator,
    source: []const u8,
    tokens: []const lex.Token,
    hash: []const u8,
    strategy: Strategy,
    out: std.ArrayList(u8) = .empty,
    copied: usize = 0,

    fn delim(self: *const Sheet, pos: usize, c: u8) bool {
        return self.tokens[pos].kind == .delim and self.source[self.tokens[pos].start] == c;
    }
    fn trivia(self: *const Sheet, pos: *usize, end: usize) void {
        while (pos.* < end and (self.tokens[pos.*].kind == .space or self.tokens[pos.*].kind == .comment)) pos.* += 1;
    }
    fn rewrite(self: *Sheet, from: usize, end: usize, nested: bool) selectors.Error!void {
        var last = end;
        while (last > from and (self.tokens[last - 1].kind == .space or self.tokens[last - 1].kind == .comment)) last -= 1;
        if (last == from) return error.InvalidCss;
        try self.out.appendSlice(self.allocator, self.source[self.copied..self.tokens[from].start]);
        const parser: selectors.Parser = .{ .allocator = self.allocator, .source = self.source, .tokens = self.tokens };
        try parser.write(&self.out, from, last, self.hash, self.strategy, nested);
        self.copied = self.tokens[last - 1].end;
    }

    fn rules(self: *Sheet, from: usize, end: usize, nested: bool, depth: usize) selectors.Error!void {
        if (depth > 128) return error.CssNestingTooDeep;
        var pos = from;
        while (pos < end) {
            self.trivia(&pos, end);
            if (pos == end) break;
            if (self.tokens[pos].kind == .cdo or self.tokens[pos].kind == .cdc or
                self.tokens[pos].kind == .close_brace or self.tokens[pos].kind == .close_paren or self.tokens[pos].kind == .close_square)
            {
                pos += 1;
                continue;
            }
            if (self.delim(pos, ';')) {
                pos += 1;
                continue;
            }
            const first = pos;
            const at_rule = self.tokens[first].kind == .at;
            // Custom-property values can contain arbitrary {} blocks and ; tokens.
            // They are component values, never nested style rules.
            var after_name = first + 1;
            self.trivia(&after_name, end);
            const custom = nested and self.tokens[first].kind == .ident and
                lex.nameStartsWith(self.source, self.tokens[first], "--") and
                after_name < end and self.delim(after_name, ':');
            while (pos < end) {
                const token = self.tokens[pos];
                if (self.delim(pos, ';')) {
                    pos += 1;
                    break;
                }
                if (token.kind == .open_brace and !custom) {
                    const checkpoint = self.out.items.len;
                    const copied = self.copied;
                    if (at_rule) {
                        self.atRule(first, pos, token.pair, nested, depth + 1) catch |err| switch (err) {
                            error.InvalidCss => {
                                self.out.shrinkRetainingCapacity(checkpoint);
                                self.copied = copied;
                            },
                            else => return err,
                        };
                    } else {
                        self.rewrite(first, pos, nested) catch |err| switch (err) {
                            error.InvalidCss => {
                                self.out.shrinkRetainingCapacity(checkpoint);
                                self.copied = copied;
                                pos = token.pair + 1;
                                break;
                            },
                            else => return err,
                        };
                        try self.rules(pos + 1, token.pair, true, depth + 1);
                    }
                    pos = token.pair + 1;
                    break;
                }
                pos = if (token.pair > pos) token.pair + 1 else pos + 1;
            }
        }
    }

    fn atRule(self: *Sheet, name: usize, opening: usize, end: usize, nested: bool, depth: usize) selectors.Error!void {
        const token = self.tokens[name];
        for ([_][]const u8{ "media", "supports", "container", "layer", "scope", "starting-style", "document", "-moz-document" }) |group| {
            if (!lex.nameIs(self.source, token, group)) continue;
            if (lex.nameIs(self.source, token, "scope")) {
                var pos = name + 1;
                while (pos < opening) {
                    const item = self.tokens[pos];
                    if (item.kind == .open_paren) try self.rewrite(pos + 1, item.pair, false);
                    pos = if (item.pair > pos) item.pair + 1 else pos + 1;
                }
            }
            try self.rules(opening + 1, end, nested, depth + 1);
            return;
        }
        // Keyframes, @font-face, @property, @page, and unknown at-rule blocks
        // have their own grammars. Keep them opaque rather than treating values
        // or animation steps as element selectors.
    }
};
