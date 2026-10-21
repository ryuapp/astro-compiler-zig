const std = @import("std");
const yuku = @import("parser");
const Ast = yuku.ast;
const Index = Ast.NodeIndex;
const Copy = @import("transform_sourcemap.zig").Copy;
const Region = @import("astro_types.zig").AstroRegion;

pub fn lower(allocator: std.mem.Allocator, tree: *Ast.Tree, frontmatter: ?Region, copies: []const Copy) !void {
    const count = tree.nodes.len;
    for (0..count) |i| {
        const id: Index = @fromBackingInt(@intCast(i));
        const data = tree.data(id);
        if (data == .import_declaration and data.import_declaration.import_kind != .type) {
            var declaration = data.import_declaration;
            const original = try allocator.dupe(Index, tree.extra(declaration.specifiers));
            var kept: std.ArrayList(Index) = .empty;
            for (original) |specifier| {
                const value = tree.data(specifier);
                if (value == .import_specifier and value.import_specifier.import_kind == .type) continue;
                try kept.append(allocator, specifier);
            }
            if (original.len > 0 and kept.items.len == 0) declaration.import_kind = .type;
            declaration.specifiers = try tree.addExtra(kept.items);
            tree.setData(id, .{ .import_declaration = declaration });
        }
        if (data == .property_definition and data.property_definition.abstract and !data.property_definition.declare and
            !data.property_definition.computed and !inFrontmatter(tree.span(id).start, frontmatter, copies))
        {
            var property = data.property_definition;
            property.abstract = false;
            tree.setData(id, .{ .property_definition = property });
        }
        if (data != .method_definition or data.method_definition.kind != .constructor) continue;
        const function = tree.data(data.method_definition.value).function;
        if (function.body == .null or function.params == .null) continue;
        const params = tree.data(function.params).formal_parameters;
        const param_ids = try allocator.dupe(Index, tree.extra(params.items));
        var assignments: std.ArrayList(Index) = .empty;
        for (param_ids) |parameter| {
            const prop = tree.data(parameter);
            if (prop != .ts_parameter_property) continue;
            tree.setData(parameter, .{ .formal_parameter = .{ .pattern = prop.ts_parameter_property.parameter } });
            var binding = prop.ts_parameter_property.parameter;
            if (tree.data(binding) == .assignment_pattern) binding = tree.data(binding).assignment_pattern.left;
            if (tree.data(binding) != .binding_identifier) continue;
            const name = tree.data(binding).binding_identifier.name;
            const span = tree.span(binding);
            const object = try tree.addNode(.{ .this_expression = .{} }, span);
            const key = try tree.addNode(.{ .identifier_name = .{ .name = name } }, span);
            const member = try tree.addNode(.{ .member_expression = .{ .object = object, .property = key, .computed = false, .optional = false } }, span);
            const value = try tree.addNode(.{ .identifier_reference = .{ .name = name } }, span);
            const assign = try tree.addNode(.{ .assignment_expression = .{ .left = member, .right = value, .operator = .assign } }, span);
            try assignments.append(allocator, try tree.addNode(.{ .expression_statement = .{ .expression = assign } }, span));
        }
        if (assignments.items.len == 0) continue;
        const body = tree.data(function.body).function_body;
        const statements = try allocator.dupe(Index, tree.extra(body.body));
        var insertion: usize = 0;
        while (insertion < statements.len and tree.data(statements[insertion]) == .directive) : (insertion += 1) {}
        for (statements, 0..) |statement, index| {
            const stmt = tree.data(statement);
            if (stmt == .expression_statement) {
                const expression = tree.data(stmt.expression_statement.expression);
                if (expression == .call_expression and tree.data(expression.call_expression.callee) == .super) {
                    insertion = index + 1;
                    break;
                }
            }
        }
        var merged: std.ArrayList(Index) = .empty;
        try merged.appendSlice(allocator, statements[0..insertion]);
        try merged.appendSlice(allocator, assignments.items);
        try merged.appendSlice(allocator, statements[insertion..]);
        tree.setData(function.body, .{ .function_body = .{ .body = try tree.addExtra(merged.items) } });
    }
    try @import("transform_runtime_typescript.zig").lower(allocator, tree);
}

fn inFrontmatter(offset: u32, region: ?Region, copies: []const Copy) bool {
    const frontmatter = region orelse return false;
    for (copies) |copy| {
        if (offset >= copy.generated and offset - copy.generated < copy.length) {
            const original = copy.original + offset - copy.generated;
            return original >= frontmatter.start and original < frontmatter.end;
        }
    }
    return false;
}
