const std = @import("std");
const Ast = @import("parser").ast;
const Index = Ast.NodeIndex;

/// Copies one already-parsed program so runtime lowering cannot mutate other regions.
pub fn cloneProgram(allocator: std.mem.Allocator, source: *const Ast.Tree, root: Index) !Ast.Tree {
    var copy: Copy = .{ .allocator = allocator, .source = source, .target = Ast.Tree.initInArena(allocator, source.source) };
    copy.target.lang = source.lang;
    copy.target.source_type = source.source_type;
    copy.target.root = try copy.reference(root);
    var position: usize = 0;
    while (position < copy.pending.items.len) : (position += 1) {
        const original = copy.pending.items[position];
        const replacement = copy.indices.get(original).?;
        switch (source.data(original)) {
            inline else => |payload, tag| {
                var value = payload;
                if (@typeInfo(@TypeOf(payload)) == .@"struct") {
                    inline for (@import("meta").fields(@TypeOf(payload))) |field| {
                        if (field.type == Index) {
                            @field(value, field.name) = try copy.reference(@field(payload, field.name));
                        } else if (field.type == Ast.IndexRange) {
                            var children: std.ArrayList(Index) = .empty;
                            for (source.extra(@field(payload, field.name))) |child| try children.append(allocator, try copy.reference(child));
                            @field(value, field.name) = try copy.target.addExtra(children.items);
                        } else if (field.type == Ast.String) {
                            @field(value, field.name) = try copy.target.addString(source.string(@field(payload, field.name)));
                        }
                    }
                }
                copy.target.setData(replacement, @unionInit(Ast.NodeData, @tagName(tag), value));
            },
        }
    }
    var comments: std.ArrayList(Ast.Comment) = .empty;
    const span = source.span(root);
    for (source.comments) |comment| {
        if (comment.span.start < span.start or comment.span.end > span.end) continue;
        var value = comment;
        value.value = try copy.target.addString(source.string(comment.value));
        try comments.append(allocator, value);
    }
    copy.target.comments = comments.items;
    return copy.target;
}

const Copy = struct {
    allocator: std.mem.Allocator,
    source: *const Ast.Tree,
    target: Ast.Tree,
    indices: std.AutoHashMapUnmanaged(Index, Index) = .empty,
    pending: std.ArrayList(Index) = .empty,

    fn reference(self: *Copy, original: Index) !Index {
        if (original == .null) return .null;
        const entry = try self.indices.getOrPut(self.allocator, original);
        if (entry.found_existing) return entry.value_ptr.*;
        const replacement = try self.target.addNode(.{ .empty_statement = .{} }, self.source.span(original));
        entry.value_ptr.* = replacement;
        try self.pending.append(self.allocator, original);
        return replacement;
    }
};
