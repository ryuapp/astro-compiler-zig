const std = @import("std");
const types = @import("astro_types.zig");

test {
    _ = @import("tsx_upstream_tests.zig");
    _ = @import("transform_sourcemap.zig");
    _ = @import("transform_allocator.zig");
}

test "editor recovery keeps partial TypeScript trees transferable" {
    for ([_][]const u8{
        "---\nconst id = <T>(x:T)=>;\n---\n<p/>",
        "---\nconst id = <T>(x:T)=>",
        "---\nconst id = <T>(x",
        "---\ninterface Props<T",
        "---\nonst id = <T>(x:T)=>x;\n---\n<p/>",
        "---\nconst id <T>(x:T)=>x;\n---\n<p/>",
        "---\nconst id = <T>(x:T)=>x;\n--\n<p>{id(x)}</p>",
        "---\ninterface Props<T> {x:T\n---\n<Component value={Astro.props.x} />",
        "---\ninterface Props<T> {x:T}\n--\n<Component value={Astro.props.x} />",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var session: ParseSession = undefined;
        try session.init(arena.allocator(), source, true);
        defer session.deinit();
        const size = try transfer.bufferSize(&session);
        const buffer = try arena.allocator().alignedAlloc(u8, .@"4", size);
        try transfer.serializeInto(&session, buffer);
        try std.testing.expectEqual(transfer.magic, std.mem.readInt(u32, buffer[0..4], .little));
    }
}

pub const endDialectExpression = @import("embedded_markup.zig").endExpression;
pub const parseDialectExpression = @import("embedded_markup.zig").expression;
pub const AstroNode = types.AstroNode;
pub const AstroAttribute = types.AstroAttribute;
pub const AstroRegion = types.AstroRegion;
pub const AstroDiagnostic = types.AstroDiagnostic;
pub const parse = @import("astro_parse.zig").parse;
pub const parseForTsx = @import("astro_parse.zig").parseForTsx;
pub const ParseSession = @import("astro_parse.zig").ParseSession;
pub const transfer = @import("astro_transfer.zig");
pub const AstroParseResult = @import("astro_parse.zig").ParseResult;
pub const TsxOptions = @import("native_tsx.zig").Options;
pub const TsxResult = @import("native_tsx.zig").Result;
pub const convertToTsx = @import("native_tsx.zig").convert;
pub const TransformOptions = @import("native_transform.zig").Options;
pub const TransformAllocator = @import("transform_allocator.zig");
pub const transform = @import("native_transform.zig").transform;
pub const extractStyles = @import("native_styles.zig").extract;

test "style preprocessing follows ordinary frontmatter JSX while retaining the public Yuku parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "---\nconst view=()=> <style>p{color:red}</style>;\n---\n<style>end</style>";
    var session: ParseSession = undefined;
    try session.init(allocator, source, false);
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 0), session.document.diagnostics.items.len);
    try std.testing.expectEqual(@as(usize, 0), (try extractStyles(allocator, source)).len);
    const blocks = try extractStyles(allocator, "{true && <style lang=scss>p{color:red}</style>}<style>end</style>");
    try std.testing.expectEqual(@as(usize, 1), blocks.len);
    try std.testing.expectEqualStrings("end", blocks[0].content);
}

fn parseYukuWithFailureInjection(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const source = "---\nconst make = (x: string) => <b>{x}</b>;\n---\n<Card {...props}>{make('\\uD800')}{/* comment */}{bad + }</Card>";
    const result = try parse(arena.allocator(), source);
    try std.testing.expectEqualStrings("AstroRoot", result.ast.object.get("type").?.string);
    try std.testing.expect(result.diagnostics.len > 0);
}

test "Yuku result arena lifetime unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, parseYukuWithFailureInjection, .{});
}

fn transformWithFailureInjection(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const source = "---\nconst text: string = '🦊日本語';\n---\n<style>p { color: red }</style>\n<p title='quoted &amp; text'>{text}</p>";
    for ([_]?[]const u8{ null, "external" }) |mode| {
        const result = try transform(arena.allocator(), source, .{ .filename = "/src/Panel.astro", .sourcemap = mode });
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
        try std.testing.expect(result.code.len > 0);
        try std.testing.expectEqual(mode != null, result.map.len > 0);
    }
}

test "transform sharing the caller arena unwinds every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, transformWithFailureInjection, .{});
}

test "transform output is identical with reserved storage and arena overflow" {
    const source = "---\nconst text: string = '🦊日本語';\n---\n<style>p { color: red }</style>\n<p title='quoted &amp; text'>{text}</p>";
    var reference = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer reference.deinit();
    const options: TransformOptions = .{ .filename = "/src/Panel.astro", .sourcemap = "external" };
    const expected = try transform(reference.allocator(), source, options);
    for ([_]usize{ 0, 64, 8192, 256 * 1024 }) |capacity| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        var scratch = TransformAllocator.init(arena.allocator(), capacity);
        const actual = try transform(scratch.allocator(), source, options);
        try std.testing.expectEqualDeep(expected, actual);
    }
}

test {
    _ = @import("js_lexical.zig");
}
