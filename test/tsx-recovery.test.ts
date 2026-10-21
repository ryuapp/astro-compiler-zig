import { assert, test } from "vite-plus/test";
import ts from "typescript-compat";
import { convertToTsx } from "../dist/index.mjs";
import { binding } from "./parse-internal.ts";
import createParser from "../src/parse.ts";
import { convertToTsx as reference } from "@astrojs/astro2tsx";
import { assertTsxCompatibility } from "./tsx-compat.ts";

const parser = createParser(binding);

test("incomplete type heads and lexical errors match reference error status and preserve mappings", () => {
  const sources = ["---\n+ /*", '---\n+ "', "---\n+ /"];
  for (const content of [
    "+",
    "interface Props<",
    "interface Props<T",
    "interface Props<T (x:T)",
    "interface Props { x: }",
    "type Shape = { : string }",
    "const id = <T>(x:T",
    "const id = <T>(x:T)=>;",
  ]) {
    sources.push("---\n" + content, "---\r\n" + content + "\r\n---\r\n<p>🦊</p>");
  }
  for (const source of sources) {
    assertTsxCompatibility(source, convertToTsx(source), reference(source), true);
  }
});

test("lowered attribute values keep comma expressions inside one object property", () => {
  for (const value of ["a, b", "", " \t\r\n"]) {
    const markup = "<C @click={" + value + "} />";
    for (const source of [markup, "{ok && " + markup + "}"]) {
      const result = convertToTsx(source);
      const expected = reference(source);
      assert.strictEqual(result.hasParseErrors, expected.hasParseErrors, source);
      if (expected.hasParseErrors) {
        assert.strictEqual(result.code, expected.code);
        assert.deepEqual(result.mappings, expected.mappings);
        assert.deepEqual(
          result.diagnostics.map((diagnostic) =>
            Object.fromEntries(Object.entries(diagnostic).filter(([key]) => key !== "message")),
          ),
          expected.diagnostics.map((diagnostic) =>
            Object.fromEntries(Object.entries(diagnostic).filter(([key]) => key !== "message")),
          ),
        );
        continue;
      }
      const file = ts.createSourceFile(
        "result.tsx",
        result.code,
        ts.ScriptTarget.Latest,
        true,
        ts.ScriptKind.TSX,
      );
      const objects: ts.ObjectLiteralExpression[] = [];
      function visit(node: ts.Node) {
        if (
          ts.isObjectLiteralExpression(node) &&
          node.properties.some(
            (property) =>
              ts.isPropertyAssignment(property) &&
              ts.isStringLiteral(property.name) &&
              property.name.text === "@click",
          )
        )
          objects.push(node);
        ts.forEachChild(node, visit);
      }
      visit(file);
      assert.strictEqual(objects.length, 1, source);
      assert.strictEqual(objects[0].properties.length, 1, source);
      const property = objects[0].properties[0];
      assert.ok(ts.isPropertyAssignment(property));
      assert.ok(ts.isParenthesizedExpression(property.initializer));
      const expression = property.initializer.expression;
      if (value.trim()) {
        assert.ok(ts.isBinaryExpression(expression));
        assert.strictEqual(expression.operatorToken.kind, ts.SyntaxKind.CommaToken);
        assert.strictEqual(expression.left.getText(file), "a");
        assert.strictEqual(expression.right.getText(file), "b");
      } else {
        assert.ok(ts.isVoidExpression(expression));
        assert.strictEqual(expression.expression.getText(file), "0");
      }
    }
  }
});

test("incomplete closing elements retain their syntax ranges instead of becoming text", () => {
  for (const source of [
    "<div>x</div",
    "<Component>x</Component \t",
    "<foo:bar>x</foo:bar\r\n",
    "<>x</",
    "<textarea><b>{value}</b></textarea  ",
  ]) {
    const { ast } = parser.parseForTsx(source);
    const root = ast.template.nodes[ast.template.rootIds[0]];
    assert.strictEqual(root.closed, false, source);
    assert.strictEqual(root.closingStart, source.lastIndexOf("</"), source);
    assert.isNotNull(root.closingStart);
    assert.strictEqual(root.closingEnd, Buffer.byteLength(source), source);
    assert.strictEqual(root.closingNameStart, root.closingStart + 2, source);
    assert.strictEqual(root.closingNameEnd, Buffer.byteLength(source.trimEnd()), source);
    for (const id of root.children)
      assert.ok(
        !ast.template.nodes[id].text.includes(source.slice(root.closingStart)),
        "The closing element must belong to its parent, not a text child",
      );
  }
});

test("malformed closing-tag recovery resumes at following markup and expressions", () => {
  for (const [source, closing, nextType] of [
    ["<div>before</div attr><span>after</span></div>", "</div attr>", "Element"],
    ["<div>before</broken<span>after</span></div>", "</broken", "Element"],
    ["<div>before</broken{value}</div>", "</broken", "Expression"],
  ]) {
    const { ast } = parser.parseForTsx(source);
    const root = ast.template.nodes[ast.template.rootIds[0]];
    const children = root.children.map((id: number) => ast.template.nodes[id]);
    const index = children.findIndex((node: any) => node.typeName === "ClosingTag");
    assert.ok(index >= 0, source);
    assert.strictEqual(children[index].text, closing);
    assert.strictEqual(children[index].closed, false);
    assert.strictEqual(children[index + 1].typeName, nextType);
    assert.strictEqual(children[index].end, children[index + 1].start);
    const result = convertToTsx(source);
    assert.strictEqual(result.hasParseErrors, true);
    assert.strictEqual(result.code.slice(result.body.start, result.body.end), source + "\n");
  }
});

test("TSX output follows parsed closing elements and preserves text modes", () => {
  for (const [source, body, errors] of [
    ["<div>x</div", "<div>x</div\n", true],
    ["<div>x</div \t", "<div>x</div \t\n", true],
    [
      "<textarea><b>{value}</b></textarea",
      "<textarea>{`<`}b{`>`}{value}{`<`}/b{`>`}</textarea\n",
      true,
    ],
    ["<title><b>{value}</b></title \n", "<title>{`<`}b{`>`}{value}{`<`}/b{`>`}</title \n\n", true],
    ["<div>x</1bad", "<div>x</1bad\n", true],
    ["<div is:raw>x</div", "<div is:raw>{`x</div`}\n", true],
    ['<p title="</div">x</p>', '<p title="</div">x</p>\n', false],
    ["<日本>hi</日本>", "{`<`}日本{`>`}hi{`<`}/日本{`>`}\n", false],
    ["<p>a < b</p>", "<p>a {`<`} b</p>\n", false],
    ["</div", "</div\n", true],
    ["\n</div>ignored", "\n</div>ignored\n", true],
    ["<!doctype html></div>", "</div>\n", true],
  ] as const) {
    const result = convertToTsx(source);
    assert.strictEqual(result.code.slice(result.body.start, result.body.end), body, source);
    assert.strictEqual(result.hasParseErrors, errors, source);
    for (const [start, length, original, originalLength, kind] of result.mappings)
      if (kind === 0)
        assert.strictEqual(
          result.code.slice(start, start + length),
          source.slice(original, original + originalLength),
          source,
        );
  }
});

test("raw script and style bodies keep incomplete closing-tag text in extracted content", () => {
  for (const [tag, content] of [
    ["script", "run();</script"],
    ["style", ".x{}</style"],
  ]) {
    const source = "<" + tag + ">" + content;
    const { ast } = parser.parseForTsx(source);
    const root = ast.template.nodes[ast.template.rootIds[0]];
    assert.strictEqual(root.closingStart, null);
    assert.ok(root.children.every((id: number) => ast.template.nodes[id].typeName === "Text"));
    const result = convertToTsx(source);
    assert.strictEqual(result.code.slice(result.body.start, result.body.end), "<" + tag + ">\n");
    const extracted = tag === "script" ? result.scripts : result.styles;
    assert.strictEqual(extracted.length, 1);
    assert.strictEqual(extracted[0].content, content);
  }
});
