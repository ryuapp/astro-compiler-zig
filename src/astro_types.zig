const std = @import("std");

/// All source positions are absolute UTF-8 byte offsets into the original file.
pub const AstroAttribute = struct {
    kind: []const u8,
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    raw: []const u8,
    start: u32,
    end: u32,
    value_start: ?u32 = null,
    value_end: ?u32 = null,
    expression: ?u32 = null,
    name_start: ?u32 = null,
    name_end: ?u32 = null,
    literal_start: ?u32 = null,
    literal_end: ?u32 = null,
};

pub const AstroNode = struct {
    id: u32,
    type_name: []const u8,
    start: ?u32,
    end: ?u32,
    text: []const u8,
    children: []const u32 = &.{},
    name: ?[]const u8 = null,
    value: ?[]const u8 = null,
    value_start: ?u32 = null,
    value_end: ?u32 = null,
    attributes: []const AstroAttribute = &.{},
    self_closing: bool = false,
    implicit_void: bool = false,
    closed: bool = true,
    raw: bool = false,
    opening_end: ?u32 = null,
    name_start: ?u32 = null,
    name_end: ?u32 = null,
    closing_start: ?u32 = null,
    closing_end: ?u32 = null,
    closing_name_start: ?u32 = null,
    closing_name_end: ?u32 = null,
    implicit_fragment: bool = false,
    spread: bool = false,
    parse_failed: bool = false,
};

pub const AstroRegion = struct {
    start: u32,
    end: u32,
    source: []const u8,
};

pub const AstroDiagnostic = struct {
    region: []const u8,
    severity: []const u8,
    message: []const u8,
    start: ?u32,
    end: ?u32,
    help: ?[]const u8 = null,
    labels: []const DiagnosticLabel = &.{},
};

pub const DiagnosticLabel = struct {
    span: struct { start: u32, end: u32 },
    message: []const u8,
};

pub fn freeDiagnostic(allocator: std.mem.Allocator, diagnostic: AstroDiagnostic) void {
    allocator.free(diagnostic.message);
    if (diagnostic.help) |help| allocator.free(help);
    for (diagnostic.labels) |label| allocator.free(label.message);
    allocator.free(diagnostic.labels);
}

pub fn freeNode(allocator: std.mem.Allocator, node: AstroNode) void {
    allocator.free(node.children);
    allocator.free(node.attributes);
}
