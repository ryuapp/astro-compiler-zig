const std = @import("std");
const Ast = @import("parser").ast;
const Index = Ast.NodeIndex;
const Allocator = std.mem.Allocator;
const yuku = @import("parser");
const Constant = union(enum) { number: f64, string: []const u8 };

pub fn lower(allocator: Allocator, tree: *Ast.Tree) !void {
    var transform: Transform = .{ .allocator = allocator, .tree = tree };
    const count = tree.nodes.len;
    var needed = false;
    for (tree.nodes.items(.data)) |value| switch (value) {
        .ts_enum_declaration => |v| {
            if (!v.declare) needed = true;
        },
        .ts_module_declaration => |v| {
            if (!v.declare) needed = true;
        },
        .ts_import_equals_declaration => |v| {
            if (v.import_kind != .type) needed = true;
        },
        else => {},
    };
    if (!needed) return;
    var visitor = struct {}{};
    const semantics = try yuku.traverser.semantic.traverse(@TypeOf(visitor), tree, &visitor);
    transform.parents = semantics.node_parents;
    for (0..count) |i| {
        const id: Index = @fromBackingInt(@intCast(i));
        if (tree.data(id) != .identifier_reference) continue;
        const symbol_id = semantics.symbolOf(id) orelse continue;
        const symbol = semantics.symbol(symbol_id);
        var owner: Index = .null;
        if (symbol.flags.enum_member) {
            owner = semantics.scope(symbol.scope).node;
            for (0..256) |_| {
                if (tree.data(owner) == .ts_enum_declaration) break;
                owner = semantics.parentOf(owner) orelse break;
            }
        } else if (symbol.flags.exported and semantics.scope(symbol.scope).kind == .ts_module) {
            var scope = semantics.scopeOf(id);
            while (scope != .none and semantics.scope(scope).kind != .ts_module) scope = semantics.scope(scope).parent;
            if (scope == symbol.scope) continue;
            owner = semantics.scope(symbol.scope).node;
            for (0..256) |_| {
                if (tree.data(owner) == .ts_module_declaration) break;
                owner = semantics.parentOf(owner) orelse break;
            }
        } else continue;
        const owner_id = switch (tree.data(owner)) {
            .ts_enum_declaration => |v| v.id,
            .ts_module_declaration => |v| v.id,
            else => continue,
        };
        const name_value = try transform.ownedName(id);
        const owner_name = try transform.ownedName(owner_id);
        transform.span = tree.span(id);
        const replacement = try transform.member(try transform.reference(owner_name), name_value);
        tree.setData(id, tree.data(replacement));
    }
    for (0..count) |i| {
        const id: Index = @fromBackingInt(@intCast(i));
        transform.span = tree.span(id);
        switch (tree.data(id)) {
            .ts_enum_declaration => |value| if (!value.declare) {
                try transform.enumDeclaration(id, value);
            },
            .ts_import_equals_declaration => |value| if (value.import_kind != .type) {
                const reference = try transform.entity(value.module_reference);
                tree.setData(id, tree.data(try transform.variable(value.id, reference, .@"var")));
            },
            else => {},
        }
    }
    for (0..count) |i| {
        const id: Index = @fromBackingInt(@intCast(i));
        transform.span = tree.span(id);
        if (tree.data(id) == .ts_module_declaration and !tree.data(id).ts_module_declaration.declare)
            try transform.namespaceDeclaration(id, tree.data(id).ts_module_declaration);
    }
}

const Transform = struct {
    allocator: Allocator,
    tree: *Ast.Tree,
    parents: []const Index = &.{},
    declarations: std.StringHashMapUnmanaged(void) = .empty,
    enum_name: []const u8 = "",
    span: Ast.Span = .{ .start = 0, .end = 0 },

    fn node(self: *Transform, value: Ast.NodeData) !Index {
        return self.tree.addNode(value, self.span);
    }
    fn reference(self: *Transform, name_value: []const u8) !Index {
        return self.node(.{ .identifier_reference = .{ .name = try self.tree.addString(name_value) } });
    }
    fn binding(self: *Transform, name_value: []const u8) !Index {
        return self.node(.{ .binding_identifier = .{ .name = try self.tree.addString(name_value) } });
    }
    fn string(self: *Transform, value: []const u8) !Index {
        return self.node(.{ .string_literal = .{ .value = try self.tree.addString(value) } });
    }
    fn number(self: *Transform, value: f64) !Index {
        if (std.math.isNan(value)) return self.reference("NaN");
        if (std.math.isInf(value)) return if (value > 0) self.reference("Infinity") else self.node(.{ .unary_expression = .{ .operator = .negate, .argument = try self.reference("Infinity") } });
        if (value < 0) return self.node(.{ .unary_expression = .{ .operator = .negate, .argument = try self.number(-value) } });
        return self.node(.{ .numeric_literal = .{ .kind = .decimal, .raw = try self.tree.addString(try std.fmt.allocPrint(self.allocator, "{d}", .{value})) } });
    }
    fn member(self: *Transform, receiver: Index, key: []const u8) !Index {
        return self.node(.{ .member_expression = .{ .object = receiver, .property = try self.string(key), .computed = true, .optional = false } });
    }
    fn assign(self: *Transform, left: Index, right: Index) !Index {
        return self.node(.{ .assignment_expression = .{ .left = left, .right = right, .operator = .assign } });
    }
    fn statement(self: *Transform, expression: Index) !Index {
        return self.node(.{ .expression_statement = .{ .expression = expression } });
    }
    fn object(self: *Transform) !Index {
        return self.node(.{ .object_expression = .{ .properties = .empty } });
    }
    fn variable(self: *Transform, id: Index, init: Index, kind: Ast.VariableKind) !Index {
        const declaration = try self.node(.{ .variable_declarator = .{ .id = id, .init = init } });
        return self.node(.{ .variable_declaration = .{ .kind = kind, .declarators = try self.tree.addExtra(&.{declaration}) } });
    }
    fn name(self: *Transform, id: Index) []const u8 {
        return switch (self.tree.data(id)) {
            inline .binding_identifier, .identifier_reference, .identifier_name => |value| self.tree.string(value.name),
            .string_literal => |value| self.tree.string(value.value),
            .template_literal => |value| if (value.expressions.len == 0) self.tree.string(self.tree.data(self.tree.extra(value.quasis)[0]).template_element.cooked) else "",
            else => "",
        };
    }
    fn ownedName(self: *Transform, id: Index) ![]const u8 {
        return self.allocator.dupe(u8, self.name(id));
    }
    fn entity(self: *Transform, id: Index) !Index {
        switch (self.tree.data(id)) {
            .ts_qualified_name => |value| {
                const key = try self.ownedName(value.right);
                return self.member(try self.entity(value.left), key);
            },
            .ts_external_module_reference => |value| {
                const call = try self.reference("require");
                return self.node(.{ .call_expression = .{ .callee = call, .arguments = try self.tree.addExtra(&.{value.expression}), .optional = false } });
            },
            .identifier_name, .binding_identifier => return self.reference(try self.ownedName(id)),
            else => return id,
        }
    }
    fn alreadyDeclared(self: *Transform, id: Index, name_value: []const u8) !bool {
        var parent = self.parents[@backingInt(id)];
        var depth: u32 = 0;
        while (parent != .null and depth < 256) : (depth += 1) {
            switch (self.tree.data(parent)) {
                .program, .function_body, .block_statement, .ts_module_block => break,
                else => parent = self.parents[@backingInt(parent)],
            }
        }
        const key = try std.fmt.allocPrint(self.allocator, "{d}:{s}", .{ @backingInt(parent), name_value });
        const result = try self.declarations.getOrPut(self.allocator, key);
        return result.found_existing;
    }
    fn factoryCall(self: *Transform, name_value: []const u8, statements: []const Index, argument: Index) !Index {
        const parameter = try self.node(.{ .formal_parameter = .{ .pattern = try self.binding(name_value) } });
        const params = try self.node(.{ .formal_parameters = .{ .items = try self.tree.addExtra(&.{parameter}), .rest = .null, .kind = .formal_parameters } });
        const body = try self.node(.{ .function_body = .{ .body = try self.tree.addExtra(statements) } });
        const function = try self.node(.{ .function = .{ .type = .function_expression, .id = .null, .params = params, .body = body, .generator = false, .async = false } });
        return self.node(.{ .call_expression = .{ .callee = function, .arguments = try self.tree.addExtra(&.{argument}), .optional = false } });
    }
    fn factory(self: *Transform, name_value: []const u8, statements: []const Index, existing: bool) !Index {
        const argument = if (existing) try self.node(.{ .logical_expression = .{ .left = try self.reference(name_value), .right = try self.object(), .operator = .@"or" } }) else try self.object();
        const call = try self.factoryCall(name_value, statements, argument);
        return if (existing) self.statement(try self.assign(try self.reference(name_value), call)) else self.variable(try self.binding(name_value), call, .let);
    }
    fn constant(self: *Transform, id: Index, values: *const std.StringHashMapUnmanaged(Constant), depth: u32) anyerror!?Constant {
        if (id == .null or depth >= 128) return null;
        return switch (self.tree.data(id)) {
            .numeric_literal => |value| .{ .number = value.value(self.tree) },
            .string_literal => |value| .{ .string = try self.allocator.dupe(u8, self.tree.string(value.value)) },
            .identifier_reference => values.get(self.name(id)),
            .member_expression => |value| if (std.mem.eql(u8, self.name(value.object), self.enum_name)) values.get(self.name(value.property)) else null,
            .parenthesized_expression => |value| self.constant(value.expression, values, depth + 1),
            .unary_expression => |value| blk: {
                const argument = (try self.constant(value.argument, values, depth + 1)) orelse break :blk null;
                if (argument != .number) break :blk null;
                break :blk .{ .number = switch (value.operator) {
                    .negate => -argument.number,
                    .positive => argument.number,
                    .bitwise_not => @floatFromInt(~toInt32(argument.number)),
                    else => break :blk null,
                } };
            },
            .binary_expression => |value| blk: {
                const left = (try self.constant(value.left, values, depth + 1)) orelse break :blk null;
                const right = (try self.constant(value.right, values, depth + 1)) orelse break :blk null;
                if (value.operator == .add and (left == .string or right == .string)) {
                    const a = if (left == .string) left.string else try std.fmt.allocPrint(self.allocator, "{d}", .{left.number});
                    const b = if (right == .string) right.string else try std.fmt.allocPrint(self.allocator, "{d}", .{right.number});
                    break :blk .{ .string = try std.mem.concat(self.allocator, u8, &.{ a, b }) };
                }
                if (left != .number or right != .number) break :blk null;
                const a = left.number;
                const b = right.number;
                const shift: u5 = @truncate(@as(u32, @bitCast(toInt32(b))));
                break :blk .{ .number = switch (value.operator) {
                    .add => a + b,
                    .subtract => a - b,
                    .multiply => a * b,
                    .divide => a / b,
                    .modulo => @rem(a, b),
                    .exponent => std.math.pow(f64, a, b),
                    .bitwise_or => @floatFromInt(toInt32(a) | toInt32(b)),
                    .bitwise_and => @floatFromInt(toInt32(a) & toInt32(b)),
                    .bitwise_xor => @floatFromInt(toInt32(a) ^ toInt32(b)),
                    .left_shift => @floatFromInt(toInt32(a) << shift),
                    .right_shift => @floatFromInt(toInt32(a) >> shift),
                    .unsigned_right_shift => @floatFromInt(@as(u32, @bitCast(toInt32(a))) >> shift),
                    else => break :blk null,
                } };
            },
            else => null,
        };
    }
    fn enumDeclaration(self: *Transform, id: Index, declaration: Ast.TSEnumDeclaration) !void {
        const enum_name = try self.ownedName(declaration.id);
        self.enum_name = enum_name;
        const existing = try self.alreadyDeclared(id, enum_name);
        const members = try self.allocator.dupe(Index, self.tree.extra(self.tree.data(declaration.body).ts_enum_body.members));
        var values: std.StringHashMapUnmanaged(Constant) = .empty;
        var output: std.ArrayList(Index) = .empty;
        var previous: ?Constant = .{ .number = -1 };
        var previous_name: []const u8 = "";
        for (members) |member_id| {
            const item = self.tree.data(member_id).ts_enum_member;
            const key = try self.ownedName(item.id);
            const value: ?Constant = if (item.initializer != .null) try self.constant(item.initializer, &values, 0) else if (previous != null and previous.? == .number) .{ .number = previous.?.number + 1 } else null;
            const expression = if (value) |known| switch (known) {
                .number => |n| try self.number(n),
                .string => |s| try self.string(s),
            } else if (item.initializer != .null) item.initializer else try self.node(.{ .binary_expression = .{ .left = try self.member(try self.reference(enum_name), previous_name), .right = try self.number(1), .operator = .add } });
            var assignment = try self.assign(try self.member(try self.reference(enum_name), key), expression);
            if (value == null or value.? != .string) {
                const reverse = try self.node(.{ .member_expression = .{ .object = try self.reference(enum_name), .property = assignment, .computed = true, .optional = false } });
                assignment = try self.assign(reverse, try self.string(key));
            }
            try output.append(self.allocator, try self.statement(assignment));
            if (value) |known| try values.put(self.allocator, key, known);
            previous = value;
            previous_name = key;
        }
        try output.append(self.allocator, try self.node(.{ .return_statement = .{ .argument = try self.reference(enum_name) } }));
        const replacement = try self.factory(enum_name, output.items, existing);
        self.tree.setData(id, self.tree.data(replacement));
    }
    fn namespaceDeclaration(self: *Transform, id: Index, declaration: Ast.TSModuleDeclaration) !void {
        if (declaration.body == .null or self.tree.data(declaration.id) == .string_literal) return;
        var names: std.ArrayList([]const u8) = .empty;
        var current = declaration.id;
        while (self.tree.data(current) == .ts_qualified_name) {
            const qualified = self.tree.data(current).ts_qualified_name;
            try names.append(self.allocator, try self.ownedName(qualified.right));
            current = qualified.left;
        }
        try names.append(self.allocator, try self.ownedName(current));
        const namespace_name = names.items[0];
        const existing = try self.alreadyDeclared(id, names.items[names.items.len - 1]);
        const body = try self.allocator.dupe(Index, self.tree.extra(self.tree.data(declaration.body).ts_module_block.body));
        var output: std.ArrayList(Index) = .empty;
        for (body) |child| {
            const value = self.tree.data(child);
            if (value != .export_named_declaration) {
                try output.append(self.allocator, child);
                continue;
            }
            const exported = value.export_named_declaration;
            if (exported.export_kind == .type or exported.declaration == .null) continue;
            try output.append(self.allocator, exported.declaration);
            const inner = self.tree.data(exported.declaration);
            if (inner == .variable_declaration) {
                const declarations = try self.allocator.dupe(Index, self.tree.extra(inner.variable_declaration.declarators));
                for (declarations) |decl| {
                    const binding_id = self.tree.data(decl).variable_declarator.id;
                    var bindings: std.ArrayList(Index) = .empty;
                    try self.patternBindings(binding_id, &bindings, 0);
                    for (bindings.items) |binding_index| {
                        const name_value = try self.ownedName(binding_index);
                        try output.append(self.allocator, try self.namespaceProperty(namespace_name, name_value, inner.variable_declaration.kind != .@"const"));
                    }
                }
            } else {
                const binding_id = switch (inner) {
                    .function => |v| v.id,
                    .class => |v| v.id,
                    else => .null,
                };
                if (binding_id != .null) {
                    const key = try self.ownedName(binding_id);
                    try output.append(self.allocator, try self.statement(try self.assign(try self.member(try self.reference(namespace_name), key), try self.reference(key))));
                }
            }
        }
        try output.append(self.allocator, try self.node(.{ .return_statement = .{ .argument = try self.reference(namespace_name) } }));
        for (names.items[0 .. names.items.len - 1], 0..) |name_value, i| {
            const parent_name = names.items[i + 1];
            const previous = try self.member(try self.reference(parent_name), name_value);
            const argument = try self.node(.{ .logical_expression = .{ .left = previous, .right = try self.object(), .operator = .@"or" } });
            const call = try self.factoryCall(name_value, output.items, argument);
            output = .empty;
            try output.append(self.allocator, try self.statement(try self.assign(try self.member(try self.reference(parent_name), name_value), call)));
            try output.append(self.allocator, try self.node(.{ .return_statement = .{ .argument = try self.reference(parent_name) } }));
        }
        const replacement = try self.factory(names.items[names.items.len - 1], output.items, existing);
        self.tree.setData(id, self.tree.data(replacement));
    }
    fn patternBindings(self: *Transform, id: Index, output: *std.ArrayList(Index), depth: u32) anyerror!void {
        if (id == .null) return;
        if (depth >= 256) return error.CodegenNestingTooDeep;
        switch (self.tree.data(id)) {
            .binding_identifier => try output.append(self.allocator, id),
            .assignment_pattern => |v| try self.patternBindings(v.left, output, depth + 1),
            inline .binding_rest_element, .binding_property => |v| {
                const child = if (@hasField(@TypeOf(v), "argument")) v.argument else v.value;
                try self.patternBindings(child, output, depth + 1);
            },
            .object_pattern => |v| {
                const children = try self.allocator.dupe(Index, self.tree.extra(v.properties));
                for (children) |child| try self.patternBindings(child, output, depth + 1);
                try self.patternBindings(v.rest, output, depth + 1);
            },
            .array_pattern => |v| {
                const children = try self.allocator.dupe(Index, self.tree.extra(v.elements));
                for (children) |child| try self.patternBindings(child, output, depth + 1);
                try self.patternBindings(v.rest, output, depth + 1);
            },
            else => {},
        }
    }
    fn namespaceProperty(self: *Transform, namespace_name: []const u8, name_value: []const u8, mutable: bool) !Index {
        var properties: std.ArrayList(Index) = .empty;
        const params = try self.node(.{ .formal_parameters = .{ .items = .empty, .rest = .null, .kind = .arrow_formal_parameters } });
        const getter = try self.node(.{ .arrow_function_expression = .{ .expression = true, .async = false, .params = params, .body = try self.reference(name_value) } });
        try properties.append(self.allocator, try self.property("get", getter));
        if (mutable) {
            const parameter_name = if (std.mem.eql(u8, name_value, "$$value")) "$$value1" else "$$value";
            const parameter = try self.node(.{ .formal_parameter = .{ .pattern = try self.binding(parameter_name) } });
            const setter_params = try self.node(.{ .formal_parameters = .{ .items = try self.tree.addExtra(&.{parameter}), .rest = .null, .kind = .arrow_formal_parameters } });
            const setter = try self.node(.{ .arrow_function_expression = .{ .expression = true, .async = false, .params = setter_params, .body = try self.assign(try self.reference(name_value), try self.reference(parameter_name)) } });
            try properties.append(self.allocator, try self.property("set", setter));
        }
        try properties.append(self.allocator, try self.property("enumerable", try self.node(.{ .boolean_literal = .{ .value = true } })));
        try properties.append(self.allocator, try self.property("configurable", try self.node(.{ .boolean_literal = .{ .value = true } })));
        const descriptor = try self.node(.{ .object_expression = .{ .properties = try self.tree.addExtra(properties.items) } });
        const callee = try self.member(try self.reference("Object"), "defineProperty");
        const arguments = try self.tree.addExtra(&.{ try self.reference(namespace_name), try self.string(name_value), descriptor });
        return self.statement(try self.node(.{ .call_expression = .{ .callee = callee, .arguments = arguments, .optional = false } }));
    }
    fn property(self: *Transform, key: []const u8, value: Index) !Index {
        return self.node(.{ .object_property = .{ .key = try self.string(key), .value = value, .kind = .init, .method = false, .shorthand = false, .computed = false } });
    }
};

fn toInt32(value: f64) i32 {
    if (!std.math.isFinite(value) or value == 0) return 0;
    const reduced = @mod(@trunc(value), 4294967296.0);
    return @bitCast(@as(u32, @intFromFloat(reduced)));
}
