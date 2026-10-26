const std = @import("std");

fn compilerModule(b: *std.Build, name: []const u8, target: std.Build.ResolvedTarget, optimize: std.lang.Optimize) *std.Build.Module {
    const yuku = b.dependency("yuku", .{
        .target = target,
        .optimize = optimize,
        .@"codegen-source-maps" = true,
        .dialect = b.path("src/astro_dialect.zig"),
    });
    const parser = yuku.module("parser");
    const meta = b.createModule(.{
        .root_source_file = b.path("src/meta.zig"),
        .target = target,
        .optimize = optimize,
    });
    const transfer = b.createModule(.{
        .root_source_file = yuku.path("src/parser/ffi/transfer/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    transfer.addImport("parser", parser);
    transfer.addImport("util", parser.import_table.get("util").?);
    const module = b.addModule(name, .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("parser", parser);
    module.addImport("yuku_transfer", transfer);
    module.addImport("util", parser.import_table.get("util").?);
    module.addImport("spec", parser.import_table.get("spec").?);
    module.addImport("meta", meta);
    parser.import_table.get("dialect").?.addImport("astro", module);
    return module;
}

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const wasm_target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .freestanding,
        .cpu_model = .{ .explicit = &std.Target.wasm.cpu.mvp },
        .cpu_features_add = std.Target.wasm.featureSet(&.{.simd128}),
    });
    const compiler = compilerModule(b, "astro_compiler_wasm", wasm_target, optimize);
    const wasm_module = b.createModule(.{
        .root_source_file = b.path("src/wasm.zig"),
        .target = wasm_target,
        .optimize = optimize,
        .single_threaded = true,
        .strip = optimize != .debug,
    });
    wasm_module.addImport("astro", compiler);
    wasm_module.addImport("meta", compiler.import_table.get("meta").?);
    const wasm = b.addExecutable(.{ .name = "compiler", .root_module = wasm_module });
    wasm.entry = .disabled;
    wasm.rdynamic = true;
    wasm.export_memory = true;
    wasm.stack_size = 8 * 1024 * 1024;
    b.installArtifact(wasm);

    const host = b.standardTargetOptions(.{});
    const module = compilerModule(b, "astro_compiler", host, optimize);
    const parser = module.import_table.get("parser").?;
    const transfer = module.import_table.get("yuku_transfer").?;
    const yuku = b.dependency("yuku", .{
        .target = host,
        .optimize = optimize,
        .@"codegen-source-maps" = true,
        .dialect = b.path("src/astro_dialect.zig"),
    });
    const generator_module = b.createModule(.{
        .root_source_file = b.path("scripts/generate-transfer.zig"),
        .target = host,
        .optimize = optimize,
    });
    generator_module.addImport("parser", parser);
    generator_module.addImport("yuku_transfer", transfer);
    generator_module.addImport("astro", module);
    generator_module.addImport("meta", module.import_table.get("meta").?);
    const generator = b.addExecutable(.{ .name = "generate-transfer", .root_module = generator_module });
    b.step("generate-transfer", "Generate the binary AST decoder").dependOn(&b.addRunArtifact(generator).step);

    b.step("test", "Run compiler tests").dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
    const test_yuku = b.step("test-yuku", "Run patched Yuku parser and codegen tests");
    test_yuku.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = parser })).step);
    test_yuku.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = transfer })).step);
    const yuku_api_tests = b.createModule(.{
        .root_source_file = yuku.path("src/parser/testing/root.zig"),
        .target = host,
        .optimize = optimize,
        .imports = &.{.{ .name = "parser", .module = parser }},
    });
    const run_yuku_api_tests = b.addRunArtifact(b.addTest(.{ .root_module = yuku_api_tests }));
    run_yuku_api_tests.setCwd(yuku.path("."));
    test_yuku.dependOn(&run_yuku_api_tests.step);
}
