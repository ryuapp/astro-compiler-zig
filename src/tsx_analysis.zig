const std = @import("std");
const yuku = @import("parser");
const text = @import("tsx_text.zig");
const Ast = yuku.ast;
const Index = Ast.NodeIndex;
const Allocator = std.mem.Allocator;
pub const Piece = struct { text: ?[]const u8 = null, start: u32 = 0, end: u32 = 0 };
pub const Edit = struct { start: u32, end: u32, order: i64 = 0, native: ?u32 = null, pieces: []const Piece = &.{} };
pub const EditorDiagnostic = struct { span: Ast.Span, message: []const u8 };
pub const Props = struct { props: bool = false, generic: []const u8 = "", args: []const u8 = "", get_static_paths: bool = false, exported: bool = false };

pub fn index(data: Ast.NodeData, comptime field: []const u8) Index {
    switch (data) {
        inline else => |value| {
            if (@typeInfo(@TypeOf(value)) == .@"struct" and @hasField(@TypeOf(value), field)) {
                if (@FieldType(@TypeOf(value), field) == Index) return @field(value, field);
            }
            return .null;
        },
    }
}
fn list(tree: *const Ast.Tree, data: Ast.NodeData, comptime field: []const u8) []const Index {
    switch (data) {
        inline else => |value| {
            if (@typeInfo(@TypeOf(value)) == .@"struct" and @hasField(@TypeOf(value), field)) {
                if (@FieldType(@TypeOf(value), field) == Ast.IndexRange) return tree.extra(@field(value, field));
            }
            return &.{};
        },
    }
}
pub const Analysis = struct {
    allocator: Allocator,
    source: []const u8,
    tree: *const Ast.Tree,
    embedded: ?*const std.AutoHashMapUnmanaged(Index, u32) = null,

    pub fn name(self: *const Analysis, id: Index) []const u8 {
        if (id == .null) return "";
        switch (self.tree.data(id)) {
            inline .binding_identifier, .identifier_reference, .identifier_name, .label_identifier, .private_identifier, .jsx_identifier => |v| return self.tree.string(v.name),
            .string_literal => |v| return self.tree.string(v.value),
            else => return "",
        }
    }
    fn binds(self: *const Analysis, initial: Index, wanted: []const u8) !bool {
        var pending: std.ArrayList(Index) = .empty;
        const seen = try self.allocator.alloc(bool, self.tree.nodes.len);
        @memset(seen, false);
        try pending.append(self.allocator, initial);
        while (pending.pop()) |id| {
            if (id == .null or @backingInt(id) >= seen.len or seen[@backingInt(id)]) continue;
            seen[@backingInt(id)] = true;
            const data = self.tree.data(id);
            switch (data) {
                .binding_identifier => if (text.eql(self.name(id), wanted)) {
                    return true;
                },
                .assignment_pattern => |v| try pending.append(self.allocator, v.left),
                .binding_rest_element => |v| try pending.append(self.allocator, v.argument),
                .object_pattern => |v| {
                    try pending.appendSlice(self.allocator, self.tree.extra(v.properties));
                    try pending.append(self.allocator, v.rest);
                },
                .array_pattern => |v| {
                    try pending.appendSlice(self.allocator, self.tree.extra(v.elements));
                    try pending.append(self.allocator, v.rest);
                },
                .binding_property => |v| try pending.append(self.allocator, v.value),
                else => {},
            }
        }
        return false;
    }
    fn declarationBinds(self: *const Analysis, id: Index, wanted: []const u8) !bool {
        if (id == .null) return false;
        const data = self.tree.data(id);
        if (data == .variable_declaration) {
            for (list(self.tree, data, "declarators")) |child| if (try self.binds(index(self.tree.data(child), "id"), wanted)) return true;
            return false;
        }
        return self.binds(index(data, "id"), wanted);
    }
    pub fn analyze(self: *const Analysis, root: ?u32, alias: ?[]const u8) !Props {
        var result: Props = .{};
        const id: Index = @fromBackingInt(@intCast(root orelse return result));
        if (id == .null or self.tree.data(id) != .program) return result;
        for (self.tree.extra(self.tree.data(id).program.body)) |initial| {
            var current = initial;
            const top = self.tree.data(initial);
            if (top == .export_named_declaration) {
                for (list(self.tree, top, "specifiers")) |spec| {
                    const specifier = self.tree.data(spec);
                    const exported = self.name(index(specifier, "exported"));
                    if (alias) |a| result.exported = result.exported or text.eql(exported, a);
                    result.get_static_paths = result.get_static_paths or (text.eql(exported, "getStaticPaths") and index(top, "source") == .null and text.eql(self.name(index(specifier, "local")), "getStaticPaths"));
                }
                const declaration = index(top, "declaration");
                if (declaration != .null) {
                    if (alias) |a| result.exported = result.exported or try self.declarationBinds(declaration, a);
                    result.get_static_paths = result.get_static_paths or try self.declarationBinds(declaration, "getStaticPaths");
                    current = declaration;
                }
            } else if (top == .export_all_declaration) {
                if (alias) |a| result.exported = result.exported or text.eql(self.name(index(top, "exported")), a);
            }
            const declaration = self.tree.data(current);
            if (declaration == .import_declaration) {
                for (list(self.tree, declaration, "specifiers")) |spec| result.props = result.props or try self.binds(index(self.tree.data(spec), "local"), "Props");
            }
            if (declaration != .ts_interface_declaration and declaration != .ts_type_alias_declaration) continue;
            if (!try self.binds(index(declaration, "id"), "Props")) continue;
            result.props = true;
            const type_parameters = index(declaration, "type_parameters");
            if (type_parameters == .null) continue;
            var generic: std.ArrayList(u8) = .empty;
            var args: std.ArrayList(u8) = .empty;
            const parameters = list(self.tree, self.tree.data(type_parameters), "params");
            for (parameters, 0..) |parameter_id, i| {
                const parameter = self.tree.data(parameter_id).ts_type_parameter;
                const parameter_name = self.name(parameter.name);
                try generic.appendSlice(self.allocator, if (i == 0) "<" else ", ");
                try args.appendSlice(self.allocator, if (i == 0) "<" else ", ");
                try generic.appendSlice(self.allocator, parameter_name);
                try args.appendSlice(self.allocator, parameter_name);
                if (parameter.constraint != .null) {
                    const span = self.tree.span(parameter.constraint);
                    try generic.appendSlice(self.allocator, " extends ");
                    try generic.appendSlice(self.allocator, self.source[span.start..span.end]);
                }
                if (parameter.default != .null) {
                    const span = self.tree.span(parameter.default);
                    try generic.appendSlice(self.allocator, " = ");
                    try generic.appendSlice(self.allocator, self.source[span.start..span.end]);
                }
            }
            if (parameters.len > 0) {
                try generic.append(self.allocator, '>');
                try args.append(self.allocator, '>');
                result.generic = generic.items;
                result.args = args.items;
            }
        }
        return result;
    }
    const Frame = struct { id: Index, depth: u32 };
    fn appendChildren(self: *const Analysis, stack: *std.ArrayList(Frame), data: Ast.NodeData, depth: u32) !void {
        switch (data) {
            inline else => |value| {
                if (@typeInfo(@TypeOf(value)) == .@"struct") inline for (@import("meta").fields(@TypeOf(value))) |field| {
                    if (field.type == Index) try stack.append(self.allocator, .{ .id = @field(value, field.name), .depth = depth });
                    if (field.type == Ast.IndexRange) for (self.tree.extra(@field(value, field.name))) |id| try stack.append(self.allocator, .{ .id = id, .depth = depth });
                };
            },
        }
    }
    fn editorDiagnostic(self: *const Analysis, diagnostics: *std.ArrayList(EditorDiagnostic), span: Ast.Span, message: []const u8) !void {
        try diagnostics.append(self.allocator, .{ .span = span, .message = message });
    }
    pub fn skipEditorDiagnostic(self: *const Analysis, original: Ast.Span) bool {
        for (self.tree.nodes.items(.data), self.tree.nodes.items(.span)) |node, span| {
            if (node == .ts_type_parameter_declaration and node.ts_type_parameter_declaration.params.len == 0 and original.start >= span.start and original.end <= span.end) return true;
            if (node == .logical_expression and ((span.start == original.start and span.end < original.end) or (span.start > original.start and span.end == original.end))) {
                const nullish = node.logical_expression.operator == .nullish_coalescing;
                for (self.tree.tokens) |token| {
                    if (token.span.start < original.start or token.span.end > original.end or (token.span.start >= span.start and token.span.end <= span.end)) continue;
                    if ((nullish and (token.tag == .logical_and or token.tag == .logical_or)) or (!nullish and token.tag == .nullish_coalescing)) return true;
                }
            }
        }
        return false;
    }
    fn editorDiagnostics(self: *const Analysis, diagnostics: *std.ArrayList(EditorDiagnostic), id: Index) !void {
        const node = self.tree.data(id);
        const span = self.tree.span(id);
        switch (node) {
            .import_declaration, .export_named_declaration, .export_all_declaration => {
                const source = index(node, "source");
                if (source == .null) return;
                const source_end = self.tree.span(source).end;
                for (self.tree.tokens, 0..) |token, i| {
                    if (token.span.start < source_end or token.span.end > span.end or token.tag != .assert) continue;
                    try self.editorDiagnostic(diagnostics, token.span, "Import assertions are not supported in editor TypeScript; use 'with'");
                    if (i + 1 < self.tree.tokens.len and self.tree.tokens[i + 1].tag == .left_brace)
                        try self.editorDiagnostic(diagnostics, self.tree.tokens[i + 1].span, "Unexpected import assertion clause");
                }
            },
            .binding_identifier, .assignment_pattern, .binding_rest_element, .array_pattern, .object_pattern, .ts_parameter_property => {
                for (list(self.tree, node, "decorators")) |decorator|
                    try self.editorDiagnostic(diagnostics, self.tree.span(decorator), "Decorators are not valid here");
            },
            .catch_clause => |clause| {
                if (clause.param == .null) return;
                const annotation = index(self.tree.data(clause.param), "type_annotation");
                if (annotation == .null) return;
                const ty = index(self.tree.data(annotation), "type_annotation");
                if (ty == .null) return;
                const data = self.tree.data(ty);
                if (data != .ts_any_keyword and data != .ts_unknown_keyword)
                    try self.editorDiagnostic(diagnostics, self.tree.span(ty), "Catch clause variable type annotation must be 'any' or 'unknown'");
            },
            inline .ts_jsdoc_nullable_type, .ts_jsdoc_non_nullable_type => |ty| {
                try self.editorDiagnostic(diagnostics, if (ty.postfix) .{ .start = span.end - 1, .end = span.end } else .{ .start = span.start, .end = span.start + 1 }, "JSDoc type operators are not valid in editor TypeScript");
                if (!ty.postfix) {
                    const inner = self.tree.span(ty.type_annotation);
                    const token_span = for (self.tree.tokens) |token| {
                        if (token.span.start == inner.start) break token.span;
                    } else inner;
                    try self.editorDiagnostic(diagnostics, token_span, "Expected a comma after a type argument");
                }
            },
            .ts_jsdoc_unknown_type => try self.editorDiagnostic(diagnostics, span, "Expected a type argument"),
            else => {},
        }
    }
    pub fn edits(self: *const Analysis, root: ?u32, diagnostics: ?*std.ArrayList(EditorDiagnostic)) ![]const Edit {
        const initial: Index = @fromBackingInt(@intCast(root orelse return &.{}));
        if (initial == .null) return &.{};
        var result: std.ArrayList(Edit) = .empty;
        var pending: std.ArrayList(Frame) = .empty;
        const seen = try self.allocator.alloc(bool, self.tree.nodes.len);
        @memset(seen, false);
        try pending.append(self.allocator, .{ .id = initial, .depth = 0 });
        if (self.tree.data(initial) == .program and self.tree.hasErrors()) {
            const region = self.tree.span(initial);
            for (self.tree.nodes.items(.data), self.tree.nodes.items(.span), 0..) |data, span, id| {
                if ((data == .ts_type_assertion or data == .arrow_function_expression) and span.start >= region.start and span.end <= region.end)
                    try pending.append(self.allocator, .{ .id = @fromBackingInt(@intCast(id)), .depth = 1 });
            }
        }
        while (pending.pop()) |frame| {
            const id = frame.id;
            if (id == .null or @backingInt(id) >= seen.len or seen[@backingInt(id)]) continue;
            seen[@backingInt(id)] = true;
            const node = self.tree.data(id);
            const span = self.tree.span(id);
            if (diagnostics) |target| try self.editorDiagnostics(target, id);
            if (node == .dialect) {
                if (self.embedded) |embedded| if (embedded.get(id)) |native_id| {
                    try result.append(self.allocator, .{ .start = span.start, .end = span.end, .native = native_id });
                    continue;
                };
            }
            if (node == .return_statement and frame.depth == 0) try result.append(self.allocator, .{ .start = span.start, .end = span.start + 6, .pieces = try self.allocator.dupe(Piece, &.{.{ .text = if (node.return_statement.argument == .null) "throw undefined" else "throw " }}) });
            if (node == .arrow_function_expression and node.arrow_function_expression.type_parameters != .null) {
                const params_id = node.arrow_function_expression.type_parameters;
                const parameters = list(self.tree, self.tree.data(params_id), "params");
                const end = self.tree.span(params_id).end;
                var trailing = false;
                if (parameters.len == 1) {
                    for (self.tree.tokens) |token| if (token.tag == .comma and token.span.start >= self.tree.span(parameters[0]).end and token.span.end < end) {
                        trailing = true;
                        break;
                    };
                    if (!trailing) try result.append(self.allocator, .{ .start = end - 1, .end = end - 1, .pieces = try self.allocator.dupe(Piece, &.{.{ .text = "," }}) });
                }
            }
            if (node == .ts_type_assertion) {
                const expression = self.tree.span(node.ts_type_assertion.expression);
                const annotation = self.tree.span(node.ts_type_assertion.type_annotation);
                const end = annotation.end + @as(u32, @intCast((std.mem.indexOfScalar(u8, self.source[annotation.end..], '>') orelse 0) + 1));
                try result.append(self.allocator, .{ .start = span.start, .end = end, .pieces = try self.allocator.dupe(Piece, &.{.{ .text = "(" }}) });
                try result.append(self.allocator, .{ .start = expression.end, .end = expression.end, .order = -@as(i64, span.start), .pieces = try self.allocator.dupe(Piece, &.{ .{ .text = " as " }, .{ .start = annotation.start, .end = annotation.end }, .{ .text = ")" } }) });
            }
            try self.appendChildren(&pending, node, frame.depth + @as(u32, if (node == .function or node == .arrow_function_expression) 1 else 0));
        }
        std.mem.sort(Edit, result.items, {}, struct {
            fn less(_: void, a: Edit, b: Edit) bool {
                return a.start < b.start or (a.start == b.start and a.order < b.order);
            }
        }.less);
        return result.items;
    }
};
