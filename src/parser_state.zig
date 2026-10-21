const Ast = @import("parser").ast;

pub fn missingOperand(tree: *const Ast.Tree, initial: Ast.NodeIndex) bool {
    var id = initial;
    for (0..256) |_| {
        if (id == .null) return false;
        switch (tree.data(id)) {
            .identifier_reference => |value| return tree.string(value.name).len == 0,
            .binary_expression => |value| id = value.right,
            .logical_expression => |value| id = value.right,
            .assignment_expression => |value| id = value.right,
            .unary_expression => |value| id = value.argument,
            .parenthesized_expression => |value| id = value.expression,
            else => return false,
        }
    }
    return false;
}
