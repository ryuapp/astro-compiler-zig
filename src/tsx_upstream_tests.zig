// Ported from astro2tsx; the source revision and all 109 test IDs are recorded
// in test/fixtures/tsx-upstream/origin.json. Public API tests live in Vitest.
const std = @import("std");
const tsx = @import("native_tsx.zig");
const printer = @import("tsx_printer.zig");
const yuku = @import("parser");
const expect = std.testing.expect;
const equal = std.testing.expectEqual;
const strings = std.testing.expectEqualStrings;

fn slice(source: []const u8, range: printer.Range) []const u8 {
    // These extraction cases are ASCII. UTF-16 offsets are covered separately.
    return source[range.start..range.end];
}

fn clean(allocator: std.mem.Allocator, source: []const u8) !tsx.Result {
    const result = try tsx.convert(allocator, source, .{});
    try expect(!result.has_parse_errors);
    var parsed = try yuku.parse(allocator, result.code, .{ .lang = .tsx });
    defer parsed.deinit();
    try expect(!parsed.hasErrors());
    var previous: u32 = 0;
    for (result.mappings) |mapping| {
        try expect(mapping[0] >= previous);
        previous = mapping[0];
        if (mapping[4] != 0) continue;
        try strings(result.code[mapping[0]..][0..mapping[1]], source[mapping[2]..][0..mapping[3]]);
    }
    return result;
}

test "src/utf16.rs:ascii_offsets_are_unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const index = try printer.Printer.init(arena.allocator(), "<p>hi</p>");
    for ([_]u32{ 0, 5, 9 }) |offset| try equal(offset, index.position(offset));
}

test "src/utf16.rs:multibyte_characters_shrink_offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const index = try printer.Printer.init(arena.allocator(), "aπb🦄c");
    for ([_][2]u32{ .{ 0, 0 }, .{ 1, 1 }, .{ 3, 2 }, .{ 4, 3 }, .{ 8, 5 }, .{ 9, 6 } }) |pair| {
        try equal(pair[1], index.position(pair[0]));
    }
}

test "src/utf16.rs:offsets_inside_a_character_clamp_to_its_start" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const index = try printer.Printer.init(arena.allocator(), "aπb");
    try equal(@as(u32, 1), index.position(2));
}

test "src/render/extracted.rs:style_tags_keep_their_position_in_html_documents" {
    for ([_][]const u8{
        "<html><body><h1>Hello world!</h1></body></html>\n<style></style>",
        "<html></html>\n<style></style>",
        "<html lang=\"en\"><head><BaseHead /></head></html>\n<style>@use \"../styles/global.scss\";</style>",
        "<html lang=\"en\"><head><BaseHead /></head><body><Header /></body></html>\n<style>@use \"../styles/global.scss\";</style>",
        "<html lang=\"en\"><head><BaseHead /></head><body><Header /></body><style>@use \"../styles/global.scss\";</style></html>",
    }) |source| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();
        const result = try clean(allocator, source);
        try equal(@as(usize, 1), result.styles.len);
        const style = result.styles[0];
        try strings(style.content, slice(source, style.position));
        const body = if (style.content.len == 0) source else try std.mem.replaceOwned(u8, allocator, source, style.content, "");
        try strings(try std.mem.concat(allocator, u8, &.{ body, "\n" }), slice(result.code, result.body));
        const range = result.generated_style_ranges[0];
        try equal(range.start, range.end);
        try expect(std.mem.endsWith(u8, result.code[0..range.start], "<style>"));
        try expect(std.mem.startsWith(u8, result.code[range.end..], "</style>"));
    }
}

test "src/render/extracted.rs:inline_script_newlines_belong_to_the_extracted_source" {
    const source = "<script is:inline>\n  const MyNumber = 3;\n  console.log(MyNumber.toStrang());\n</script>\n";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try clean(arena.allocator(), source);
    try equal(@as(usize, 1), result.scripts.len);
    const script = result.scripts[0];
    try equal(std.mem.indexOfScalar(u8, source, '\n').?, script.position.start);
    try strings("\n  const MyNumber = 3;\n  console.log(MyNumber.toStrang());\n", script.content);
    try strings(script.content, slice(source, script.position));
    const range = result.generated_script_ranges[0];
    try equal(range.start, range.end);
    try expect(std.mem.indexOf(u8, result.code, "<script is:inline></script>") != null);
}

test "src/render/extracted.rs:extracted_ranges_are_generated_offsets" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const styled = try tsx.convert(allocator, "<div style=\"color:red\"></div>", .{});
    try strings("color:red", slice(styled.code, styled.generated_style_ranges[0]));
    const scripted = try tsx.convert(allocator, "<div onclick=\"go()\"></div>", .{});
    try strings("go()", slice(scripted.code, scripted.generated_script_ranges[0]));
    const tag = try tsx.convert(allocator, "<style>.a{color:red}</style>", .{});
    const range = tag.generated_style_ranges[0];
    try equal(range.start, range.end);
    try expect(std.mem.endsWith(u8, tag.code[0..range.start], "<style>"));
    try expect(std.mem.startsWith(u8, tag.code[range.end..], "</style>"));
}

test "src/render/extracted.rs:extracted_attribute_ranges_slice_to_content_with_inner_quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try tsx.convert(arena.allocator(), "<div style='a:\"x\"' onclick='go(\"y\")'></div>", .{});
    try strings(result.styles[0].content, slice(result.code, result.generated_style_ranges[0]));
    try strings(result.scripts[0].content, slice(result.code, result.generated_script_ranges[0]));
}

test "src/render/extracted.rs:jsx_path_extracts_event_and_style_attributes" {
    const source = "{x && <div onclick=\"go()\" style=\"color:red\"></div>}";
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try tsx.convert(arena.allocator(), source, .{});
    try equal(@as(usize, 1), result.scripts.len);
    try equal(@as(usize, 1), result.styles.len);
    try strings("go()", result.scripts[0].content);
    try strings("color:red", result.styles[0].content);
    for (result.scripts, result.generated_script_ranges) |script, range| {
        try strings(script.content, slice(result.code, range));
        try strings(script.content, slice(source, script.position));
    }
    for (result.styles, result.generated_style_ranges) |style, range| {
        try strings(style.content, slice(result.code, range));
        try strings(style.content, slice(source, style.position));
    }
}
