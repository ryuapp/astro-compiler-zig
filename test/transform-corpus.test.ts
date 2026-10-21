import { createRequire as createModuleRequire } from "node:module";
import fs from "node:fs";
import path from "node:path";
import { assert, test } from "vite-plus/test";
import { TraceMap, decodedMappings, originalPositionFor } from "@jridgewell/trace-mapping";
import * as api from "../dist/index.mjs";
import { errorProbes } from "./fixtures/transform-sourcemap-inputs.ts";
import { canonicalCss } from "./css-compat.ts";
import scriptBoundaries from "./fixtures/script-boundary-reference.json" with { type: "json" };
const require = createModuleRequire(import.meta.url);
const ts = require("typescript-compat");
const official = await import("@astrojs/compiler-rs");
const folder = path.resolve("test/fixtures/transform-upstream/fixtures");
function syntax(source: string) {
  const tree = ts.createSourceFile(
    "output.ts",
    source,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  if (tree.parseDiagnostics.length)
    throw Error(ts.flattenDiagnosticMessageText(tree.parseDiagnostics[0].messageText, " "));
  function normalize(node: any) {
    if (ts.isParenthesizedExpression(node)) return normalize(node.expression);
    if (
      node.parent?.name === node &&
      (ts.isPropertyAssignment(node.parent) || ts.isMethodDeclaration(node.parent)) &&
      (ts.isIdentifier(node) || ts.isStringLiteral(node))
    )
      return ["key", node.text];
    const kids = node.getChildren(tree).map(normalize).filter(Boolean);
    if (kids.length) return [node.kind, ...kids];
    if ([ts.SyntaxKind.EndOfFileToken, ts.SyntaxKind.SemicolonToken].includes(node.kind))
      return null;
    if (ts.isStringLiteral(node)) return [ts.SyntaxKind.StringLiteral, node.text];
    if (
      [
        ts.SyntaxKind.NoSubstitutionTemplateLiteral,
        ts.SyntaxKind.TemplateHead,
        ts.SyntaxKind.TemplateMiddle,
        ts.SyntaxKind.TemplateTail,
      ].includes(node.kind)
    ) {
      let parent = node.parent;
      while (parent && !ts.isTaggedTemplateExpression(parent)) parent = parent.parent;
      if (parent?.tag.getText(tree) === "$$render")
        return [
          node.kind,
          node.text.replace(
            /(<style\b[^>]*>)([\s\S]*?)(<\/style>)/gu,
            (_: string, open: string, css: string, close: string) =>
              open + canonicalCss(css) + close,
          ),
        ];
    }
    if (ts.isNumericLiteral(node)) return [node.kind, Number(node.text)];
    return [node.kind, node.text ?? ""];
  }
  return normalize(tree);
}
// Coordinates differ with the JS printer. Check that every segment refers to
// an existing generated/original position; this does not prove semantic accuracy.
function validateMap(code: string, encoded: string, source: string, filename: string) {
  assert.ok(encoded, "Missing external source map");
  const map = JSON.parse(encoded);
  assert.strictEqual(map.version, 3);
  assert.deepEqual(map.sources, [filename]);
  assert.deepEqual(map.sourcesContent, [source]);
  const generated = code.split(/\r\n|[\r\n\u2028\u2029]/u);
  const original = source.split(/\r\n|[\r\n\u2028\u2029]/u);
  let points = 0;
  for (const [line, segments] of decodedMappings(new TraceMap(map)).entries()) {
    let previous = -1;
    for (const segment of segments) {
      assert.ok(
        line < generated.length && segment[0] <= generated[line].length,
        "Generated position outside code: " + JSON.stringify({ line, segment }),
      );
      assert.ok(segment[0] >= 0 && segment[0] >= previous, "Unordered generated columns");
      previous = segment[0];
      if (segment.length === 1) continue;
      assert.ok(
        segment[1] === 0 &&
          segment[2] >= 0 &&
          segment[2] < original.length &&
          segment[3] >= 0 &&
          segment[3] <= original[segment[2]].length,
        "Original position outside source: " + JSON.stringify(segment),
      );
      points++;
    }
  }
  return points;
}
for (const entry of fs.readdirSync(folder, { recursive: true, withFileTypes: true })) {
  if (!entry.isFile() || !entry.name.endsWith(".astro")) continue;
  const file = path.join(entry.parentPath, entry.name);
  test("transform corpus: " + path.relative(folder, file), () => {
    let source = fs.readFileSync(file, "utf8");
    const options: Record<string, any> = {
      filename: "/src/" + path.relative(folder, file).replaceAll("\\", "/"),
      sourcemap: "external",
      internalURL: "http://localhost:3000/",
      astroGlobalArgs: '"https://astro.build"',
    };
    while (source.startsWith("// @config ")) {
      const newline = source.indexOf("\n");
      const line = source.slice(0, newline < 0 ? source.length : newline).trimEnd();
      const [key, value] = line.slice("// @config ".length).split("=");
      if (key === "compact")
        options.compact = value === "html" ? true : value === "jsx" ? "jsx" : undefined;
      if (key === "inlineComponentAssets") options.inlineComponentAssets = value === "true";
      if (key === "annotateSourceFile") {
        options.annotateSourceFile = value === "true";
        if (options.annotateSourceFile) options.filename = "/src/pages/annotation.astro";
      }
      source = newline < 0 ? "" : source.slice(newline + 1);
    }
    const expected = official.transform(source, options);
    const correction = scriptBoundaries.transform.find((fixture) => fixture.source === source);
    if (correction) {
      assert.deepEqual<unknown>({ ...options }, correction.options);
      assert.strictEqual(expected.code, correction.publishedCode);
      expected.code = correction.expectedCode;
    }
    const actual = api.transform(source, options);
    for (const key of Object.keys(expected)) {
      if (["code", "map", "scripts", "diagnostics", "css"].includes(key)) continue;
      assert.deepEqual(
        actual[key as keyof typeof actual],
        expected[key as keyof typeof expected],
        key,
      );
    }
    assert.deepEqual(actual.css.map(canonicalCss), expected.css.map(canonicalCss));
    assert.strictEqual(
      actual.diagnostics.some((d) => d.severity === "error"),
      expected.diagnostics.some((d) => d.severity === "error"),
    );
    assert.strictEqual(actual.scripts.length, expected.scripts.length);
    for (const [index, script] of actual.scripts.entries()) {
      const ref = expected.scripts[index];
      assert.strictEqual(script.type, ref.type);
      assert.strictEqual(script.src, ref.src);
      if (script.code) assert.deepEqual(syntax(script.code), syntax(ref.code!));
    }
    assert.deepEqual(syntax(actual.code), syntax(expected.code));
    if (actual.diagnostics.some((d) => d.severity === "error")) {
      assert.strictEqual(actual.code, "");
      assert.strictEqual(actual.map, "");
    } else validateMap(actual.code, actual.map, source, options.filename);
  });
}
// Exercise source locations independently of either compiler's map encoding.
// These probes catch valid-looking maps that point to the wrong source line.
function position(source: string, snippet: string) {
  const offset = source.indexOf(snippet);
  assert.ok(offset >= 0, "Missing source-map probe: " + snippet);
  const lines = source.slice(0, offset).split(/\r\n|[\r\n\u2028\u2029]/u);
  return { line: lines.length, column: lines.at(-1)!.length };
}
const sourceMapProbes = [
  ...errorProbes.map(([name, source]) => ({
    name,
    source,
    generated: "new Error(",
    original: "throw",
    exactColumn: false,
    options: {} as api.TransformOptions,
  })),
  ...[false, true].map((resolve) => ({
    name: resolve ? "resolved-path-length" : "original-path-length",
    source: '---\nimport C from "./C.jsx";\n---\n<C client:load/><p>{__marker}</p>',
    generated: "__marker",
    original: "{__marker}",
    exactColumn: true,
    options: resolve
      ? { resolvePath: (specifier: string) => "/very/long/resolved/path/to/" + specifier }
      : {},
  })),
];
for (const probe of sourceMapProbes)
  test("transform corpus source map: " + probe.name, () => {
    const filename = "/src/MapProbe.astro";
    const result = api.transform(probe.source, {
      ...probe.options,
      filename,
      sourcemap: "external",
    });
    const generated = position(result.code, probe.generated);
    const expected = position(probe.source, probe.original);
    const actual = originalPositionFor(new TraceMap(result.map), generated);
    assert.strictEqual(actual.source, filename);
    assert.strictEqual(actual.line, expected.line);
    if (probe.exactColumn) assert.strictEqual(actual.column, expected.column);
  });
