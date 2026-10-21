const std = @import("std");
const lex = @import("css_lexer.zig");
pub const Strategy = enum { where, class, attribute };
pub const Error = lex.Error || error{CssSelectorExpansionTooLarge};
const Relation = enum { none, descendant, child, next, subsequent, column };
const Kind = enum { type, universal, class, id, attribute, pseudo, pseudo_element, global, nesting };
const Simple = struct {
    kind: Kind,
    start: usize,
    end: usize,
    name: usize = 0,
    arguments: ?*const List = null,
    inner_start: usize = 0,
    inner_end: usize = 0,
};
const Compound = struct { relation: Relation, simples: []const Simple, scope: bool = false };
const Selector = struct { compounds: []const Compound };
const List = struct { selectors: []const Selector, nesting: bool = false };

pub const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    tokens: []const lex.Token,

    fn delim(self: Parser, index: usize, c: u8) bool {
        return index < self.tokens.len and self.tokens[index].kind == .delim and self.source[self.tokens[index].start] == c;
    }
    fn trivia(self: Parser, pos: *usize, end: usize) void {
        while (pos.* < end and (self.tokens[pos.*].kind == .space or self.tokens[pos.*].kind == .comment)) pos.* += 1;
    }
    fn comments(self: Parser, pos: *usize, end: usize) void {
        while (pos.* < end and self.tokens[pos.*].kind == .comment) pos.* += 1;
    }
    fn relation(self: Parser, pos: *usize, end: usize) ?Relation {
        if (pos.* >= end) return null;
        const token = self.tokens[pos.*];
        if (token.kind != .delim) return null;
        var next = pos.* + 1;
        self.comments(&next, end);
        const result: Relation = switch (self.source[token.start]) {
            '>' => .child,
            '+' => .next,
            '~' => .subsequent,
            '|' => if (next < end and self.delim(next, '|')) .column else return null,
            else => return null,
        };
        pos.* = if (result == .column) next + 1 else pos.* + 1;
        return result;
    }

    fn simple(self: Parser, pos: *usize, end: usize, depth: usize, first_in_compound: bool) Error!Simple {
        const index = pos.*;
        const token = self.tokens[index];
        pos.* += 1;
        var result: Simple = .{ .kind = .type, .start = token.start, .end = token.end, .name = index };
        if (token.kind == .ident or self.delim(index, '*') or self.delim(index, '|')) {
            var next = pos.*;
            self.comments(&next, end);
            var after_pipe = next + 1;
            self.comments(&after_pipe, end);
            if (self.delim(index, '|') or (next < end and self.delim(next, '|') and !(after_pipe < end and self.delim(after_pipe, '|')))) {
                pos.* = if (self.delim(index, '|')) next else after_pipe;
                if (pos.* == end or !(self.tokens[pos.*].kind == .ident or self.delim(pos.*, '*'))) return error.InvalidCss;
                result.name = pos.*;
                result.end = self.tokens[pos.*].end;
                pos.* += 1;
            }
            if (self.delim(result.name, '*')) result.kind = .universal;
        } else if (self.delim(index, '.')) {
            self.comments(pos, end);
            if (pos.* == end or self.tokens[pos.*].kind != .ident) return error.InvalidCss;
            result.kind = .class;
            result.end = self.tokens[pos.*].end;
            pos.* += 1;
        } else if (token.kind == .hash) {
            result.kind = .id;
        } else if (token.kind == .open_square) {
            result.kind = .attribute;
            result.end = self.tokens[token.pair].end;
            pos.* = token.pair + 1;
        } else if (self.delim(index, '&')) {
            result.kind = .nesting;
        } else if (self.delim(index, ':')) {
            result.kind = .pseudo;
            self.comments(pos, end);
            if (pos.* < end and self.delim(pos.*, ':')) {
                result.kind = .pseudo_element;
                pos.* += 1;
            }
            self.comments(pos, end);
            if (pos.* == end) return error.InvalidCss;
            result.name = pos.*;
            const name = self.tokens[pos.*];
            if (name.kind != .ident and name.kind != .function) return error.InvalidCss;
            result.end = name.end;
            pos.* += 1;
            if (name.kind == .function) {
                const close = name.pair;
                result.end = self.tokens[close].end;
                const from = result.name + 1;
                const pseudo_class = result.kind == .pseudo;
                const global = pseudo_class and lex.nameIs(self.source, name, "global");
                const single = (pseudo_class and lex.nameIs(self.source, name, "host")) or
                    (result.kind == .pseudo_element and lex.nameIs(self.source, name, "slotted"));
                var selectors = global;
                if (pseudo_class) for ([_][]const u8{ "is", "where", "not", "has", "-webkit-any", "-moz-any" }) |item| {
                    if (lex.nameIs(self.source, name, item)) selectors = true;
                };
                selectors = selectors or single;
                // Match the reference's structured selector variants. nth-child's
                // `of` list and custom functions (including host-context) are opaque.
                if (selectors) {
                    var first = from;
                    self.trivia(&first, close);
                    if (first < close) {
                        const forgiving = global or lex.nameIs(self.source, name, "is") or lex.nameIs(self.source, name, "where");
                        result.arguments = self.list(from, close, false, false, forgiving, depth + 1) catch |err| switch (err) {
                            error.InvalidCss => if (forgiving) null else return err,
                            else => return err,
                        };
                        // :host() and ::slotted() can contain only one selector.
                        // If a global list would expand it, keep the original argument.
                        if (single and result.arguments != null and !singleExpansion(result.arguments.?)) result.arguments = null;
                        result.inner_start = name.end;
                        result.inner_end = self.tokens[close].start;
                        if (global and result.arguments != null) result.kind = .global;
                    }
                }
                pos.* = close + 1;
            }
        } else return error.InvalidCss;
        if (!first_in_compound and (result.kind == .type or result.kind == .universal)) return error.InvalidCss;
        return result;
    }

    fn singleExpansion(value: *const List) bool {
        if (value.selectors.len != 1) return false;
        for (value.selectors[0].compounds) |compound| for (compound.simples) |item| {
            if (item.kind == .global and !singleExpansion(item.arguments.?)) return false;
        };
        return true;
    }

    fn list(self: Parser, from: usize, end: usize, scoped: bool, nested: bool, forgiving: bool, depth: usize) Error!*const List {
        if (depth > 128) return error.CssNestingTooDeep;
        var selectors: std.ArrayList(Selector) = .empty;
        var nesting = false;
        var pos = from;
        self.trivia(&pos, end);
        next_selector: while (pos < end) {
            if (forgiving and self.delim(pos, ',')) {
                pos += 1;
                self.trivia(&pos, end);
                continue;
            }
            var compounds: std.ArrayList(Compound) = .empty;
            const selector_start = pos;
            var next_relation: Relation = .none;
            while (pos < end and !self.delim(pos, ',')) {
                if (self.relation(&pos, end)) |value| next_relation = value;
                self.trivia(&pos, end);
                var simples: std.ArrayList(Simple) = .empty;
                while (pos < end and self.tokens[pos].kind != .space and !self.delim(pos, ',')) {
                    if (self.tokens[pos].kind == .comment) {
                        pos += 1;
                        continue;
                    }
                    var peek = pos;
                    if (self.relation(&peek, end) != null) break;
                    const item = self.simple(&pos, end, depth, simples.items.len == 0) catch |err| {
                        if (!forgiving or err != error.InvalidCss) return err;
                        pos = selector_start;
                        while (pos < end and !self.delim(pos, ',')) {
                            const skipped = self.tokens[pos];
                            pos = if (skipped.pair > pos) skipped.pair + 1 else pos + 1;
                        }
                        if (pos < end) pos += 1;
                        self.trivia(&pos, end);
                        continue :next_selector;
                    };
                    try simples.append(self.allocator, item);
                }
                if (simples.items.len == 0) return error.InvalidCss;
                try compounds.append(self.allocator, .{ .relation = next_relation, .simples = try simples.toOwnedSlice(self.allocator) });
                next_relation = .descendant;
                self.trivia(&pos, end);
            }
            if (compounds.items.len == 0) return error.InvalidCss;
            var top_nesting = false;
            var any_nesting = false;
            for (compounds.items) |compound| for (compound.simples) |item| {
                if (item.kind == .nesting) top_nesting = true;
                if (item.arguments) |arguments| any_nesting = any_nesting or arguments.nesting;
            };
            any_nesting = any_nesting or top_nesting;
            nesting = nesting or any_nesting;
            const implicit = nested and !any_nesting;
            const leading_bare = implicit or (compounds.items[0].simples.len == 1 and compounds.items[0].simples[0].kind == .nesting);
            for (compounds.items, 0..) |*compound, index| {
                var global = false;
                var local = false;
                var parent = false;
                for (compound.simples) |item| {
                    if (item.kind == .global) global = true;
                    if (item.kind == .nesting) parent = true;
                    if (!global and item.kind != .pseudo and item.kind != .pseudo_element) local = true;
                }
                const descendant = compound.relation == .descendant or (implicit and index == 0 and compound.relation == .none);
                compound.scope = scoped and !parent and !(any_nesting and !top_nesting) and
                    !(leading_bare and descendant) and (!global or local);
            }
            try selectors.append(self.allocator, .{ .compounds = try compounds.toOwnedSlice(self.allocator) });
            if (pos == end) break;
            pos += 1;
            self.trivia(&pos, end);
            if (pos == end and !forgiving) return error.InvalidCss;
        }
        if (selectors.items.len == 0) return error.InvalidCss;
        const result = try self.allocator.create(List);
        result.* = .{ .selectors = try selectors.toOwnedSlice(self.allocator), .nesting = nesting };
        return result;
    }

    pub fn write(self: Parser, out: *std.ArrayList(u8), from: usize, end: usize, hash: []const u8, strategy: Strategy, nested: bool) Error!void {
        const parsed = try self.list(from, end, true, nested, false, 0);
        var writer: Writer = .{ .parser = self, .out = out, .hash = hash, .strategy = strategy };
        try writer.list(parsed, 0);
    }
};

const Writer = struct {
    parser: Parser,
    out: *std.ArrayList(u8),
    hash: []const u8,
    strategy: Strategy,
    variants: usize = 0,

    fn put(self: *Writer, source: []const u8) Error!void {
        try self.out.appendSlice(self.parser.allocator, source);
    }
    fn suffix(self: *Writer) Error!void {
        try self.put(switch (self.strategy) {
            .where => ":where(.astro-",
            .class => ".astro-",
            .attribute => "[data-astro-cid-",
        });
        try self.put(self.hash);
        try self.put(switch (self.strategy) {
            .where => ")",
            .class => "",
            .attribute => "]",
        });
    }
    fn merge(self: *Writer, a: []const Simple, b: []const Simple) Error![]const Simple {
        const result = try self.parser.allocator.alloc(Simple, a.len + b.len);
        @memcpy(result[0..a.len], a);
        @memcpy(result[a.len..], b);
        return result;
    }
    fn list(self: *Writer, value: *const List, depth: usize) Error!void {
        var first = true;
        for (value.selectors) |selector| try self.expand(selector, depth, &first);
    }
    fn expand(self: *Writer, selector: Selector, depth: usize, first: *bool) Error!void {
        if (depth > 128) return error.CssNestingTooDeep;
        for (selector.compounds, 0..) |compound, c| for (compound.simples, 0..) |item, s| {
            if (item.kind != .global) continue;
            for (item.arguments.?.selectors) |inner| {
                var parts: std.ArrayList(Compound) = .empty;
                try parts.appendSlice(self.parser.allocator, selector.compounds[0..c]);
                const before = compound.simples[0..s];
                const after = compound.simples[s + 1 ..];
                var first_inner = inner.compounds[0];
                if (first_inner.relation != .none and before.len > 0) {
                    try parts.append(self.parser.allocator, .{ .relation = compound.relation, .simples = before, .scope = compound.scope });
                } else {
                    first_inner.relation = if (first_inner.relation == .none) compound.relation else first_inner.relation;
                    first_inner.simples = try self.merge(before, first_inner.simples);
                    first_inner.scope = compound.scope;
                }
                try parts.append(self.parser.allocator, first_inner);
                try parts.appendSlice(self.parser.allocator, inner.compounds[1..]);
                const last = &parts.items[parts.items.len - 1];
                last.simples = try self.merge(last.simples, after);
                try parts.appendSlice(self.parser.allocator, selector.compounds[c + 1 ..]);
                try self.expand(.{ .compounds = parts.items }, depth + 1, first);
            }
            return;
        };
        self.variants += 1;
        if (self.variants > 4096) return error.CssSelectorExpansionTooLarge;
        if (!first.*) try self.put(", ");
        first.* = false;
        for (selector.compounds, 0..) |compound, index| {
            switch (compound.relation) {
                .none => {},
                .descendant => if (index > 0) try self.put(" "),
                .child, .next, .subsequent, .column => {
                    if (index > 0) try self.put(" ");
                    try self.put(switch (compound.relation) {
                        .child => "> ",
                        .next => "+ ",
                        .subsequent => "~ ",
                        .column => "|| ",
                        else => unreachable,
                    });
                },
            }
            try self.writeCompound(compound, depth);
        }
    }
    fn atom(self: *Writer, item: Simple, depth: usize) Error!void {
        if (item.arguments) |arguments| {
            try self.put(self.parser.source[item.start..item.inner_start]);
            try self.list(arguments, depth + 1);
            try self.put(self.parser.source[item.inner_end..item.end]);
        } else try self.put(self.parser.source[item.start..item.end]);
    }
    fn writeCompound(self: *Writer, value: Compound, depth: usize) Error!void {
        var scope = value.scope;
        var only_pseudo = true;
        var types: usize = 0;
        for (value.simples) |item| {
            if (item.kind == .type or item.kind == .universal) types += 1;
            if (item.kind == .type and (lex.nameIsExact(self.parser.source, self.parser.tokens[item.name], "html") or lex.nameIsExact(self.parser.source, self.parser.tokens[item.name], "body"))) scope = false;
            if (item.kind != .pseudo and item.kind != .pseudo_element) only_pseudo = false;
        }
        if (types > 1) return error.InvalidCss;
        var injected = !scope;
        // Keep expansion order, including global type selectors, as in the
        // reference printer. Moving a type to the front changes its output.
        for (value.simples, 0..) |item, index| {
            if (item.kind == .type or item.kind == .universal) {
                try self.atom(item, depth);
                if (!injected) {
                    try self.suffix();
                    injected = true;
                }
                continue;
            }
            const root = item.kind == .pseudo and lex.nameIs(self.parser.source, self.parser.tokens[item.name], "root");
            if (root) injected = true;
            if (!injected and (item.kind == .attribute or item.kind == .pseudo_element or (only_pseudo and index == 0))) {
                try self.suffix();
                injected = true;
            }
            try self.atom(item, depth);
            if (!injected and (item.kind == .class or item.kind == .id)) {
                try self.suffix();
                injected = true;
            }
        }
        if (!injected) try self.suffix();
    }
};
