const yuku = @import("parser");

pub const files: []const yuku.dialect.File = &.{.{ .extension = ".astro", .lang = .tsx }};

pub const Node = enum {
    document,
    element,
    component,
    fragment,
    text,
    expression,
    comment,
    doctype,
    script,
    style,
    closing_tag,

    pub fn shape(kind: Node) yuku.dialect.Shape {
        const types = [_][]const u8{
            "AstroDocument", "AstroElement",    "AstroComponent",  "AstroFragment",
            "AstroText",     "AstroExpression", "AstroComment",    "AstroDoctype",
            "AstroScript",   "AstroStyle",      "AstroClosingTag",
        };
        return .{ .type = types[@backingInt(kind)], .fields = &.{"children[]"} };
    }
};

pub fn operator(
    parser: *yuku.dialect.Parser,
    left: yuku.ast.NodeIndex,
    precedence: u8,
) yuku.dialect.Error!yuku.dialect.Claim {
    _ = precedence;
    return @import("astro").endDialectExpression(parser, left);
}

pub fn expression(parser: *yuku.dialect.Parser) yuku.dialect.Error!yuku.dialect.Claim {
    return @import("astro").parseDialectExpression(parser);
}
