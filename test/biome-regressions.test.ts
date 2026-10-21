import { assert, test } from "vite-plus/test";
import ts from "typescript-compat";
import { convertToTsx } from "../dist/index.mjs";
import { assertSyntax, assertVerbatim, assertReference } from "./tsx-upstream/helpers.ts";

test("expression shorthand attributes follow the published converter in both contexts", () => {
  const expressions = ["object?.something", "props.foo", "call()", "{answer:4}", "a, b"];
  const markup = "<C " + expressions.map((value) => "{" + value + "}").join(" ") + " />";
  for (const source of [markup, "{ok && " + markup + "}"]) {
    const result = convertToTsx(source);
    assertReference(source);
    assertVerbatim(source, result);
    if (source === markup)
      for (const value of expressions) assert.ok(result.code.includes(value + "={" + value + "}"));
  }
});

test("JavaScript comments between expression siblings stay comments rather than visible text", () => {
  for (const source of [
    "{<p>a</p>/* c */<div />}",
    "{<p/> // c\n<div/>}",
    "{<p/>/* } */<div/>/* trailing */}",
    "{<p/>/* trailing */}",
    "{/* leading */<p/>}",
  ]) {
    const result = convertToTsx(source);
    assert.strictEqual(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
    assertSyntax(result.code);
    assertVerbatim(source, result);
    const file = ts.createSourceFile(
      "output.tsx",
      result.code,
      ts.ScriptTarget.Latest,
      true,
      ts.ScriptKind.TSX,
    );
    function visit(node: ts.Node) {
      if (ts.isJsxText(node))
        assert.ok(!node.text.includes("/*") && !node.text.includes("//"), source);
      ts.forEachChild(node, visit);
    }
    visit(file);
    assert.ok(result.code.includes(source.includes("//") ? "// c" : "/*"), source);
  }
  const source = "<p>/* visible */</p>";
  const result = convertToTsx(source);
  assert.strictEqual(result.hasParseErrors, false);
  assert.ok(result.code.includes("<p>/* visible */</p>"));
});

test("bare closing braces are diagnosed only in expression JSX text", () => {
  for (const [source, error] of [
    ["<p>a } b</p>", false],
    ["{ok && <p>a } b</p>}", true],
    ["{<p>a } b</p>}", true],
    ["{ok && <math>a } b</math>}", true],
    ["{ok && <div is:raw>a } b</div>}", false],
  ] as const) {
    const result = convertToTsx(source);
    assert.strictEqual(result.hasParseErrors, error, source);
    assertVerbatim(source, result);
    if (!error) assertSyntax(result.code);
  }
});
