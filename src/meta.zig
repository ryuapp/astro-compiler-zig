const Field = struct { name: [:0]const u8, type: type, value: comptime_int };

pub inline fn fields(comptime T: type) []const Field {
    return comptime blk: {
        @setEvalBranchQuota(100_000);
        const info = @typeInfo(T);
        const names = switch (info) {
            .@"struct" => |v| v.field_names,
            .@"union" => |v| v.field_names,
            .@"enum" => |v| v.field_names,
            else => @compileError("expected a struct, union or enum"),
        };
        var result: [names.len]Field = undefined;
        for (names, 0..) |name, i| {
            result[i] = .{
                .name = name,
                .type = switch (info) {
                    .@"struct" => |v| v.field_types[i],
                    .@"union" => |v| v.field_types[i],
                    else => void,
                },
                .value = if (info == .@"enum") info.@"enum".field_values[i] else 0,
            };
        }
        const output = result;
        break :blk &output;
    };
}
