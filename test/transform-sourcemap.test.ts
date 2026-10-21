import { createRequire } from "node:module";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { assert, test } from "vite-plus/test";
import { TraceMap, decodedMappings, originalPositionFor } from "@jridgewell/trace-mapping";
import ts from "typescript-compat";
import { transform, type TransformResult } from "../dist/index.mjs";
import { errorProbes, pathSource, resolvedPaths } from "./fixtures/transform-sourcemap-inputs.ts";

const require = createRequire(import.meta.url);
const astro = path.dirname(require.resolve("astro/package.json"));
const { experimental_AstroContainer: AstroContainer } = await import(
  pathToFileURL(path.join(astro, "dist/container/index.js")).href
);
const container = await AstroContainer.create();
const internalURL = pathToFileURL(path.join(astro, "dist/runtime/server/index.js")).href;
const filename = "/src/MapProbe.astro";

function position(source: string, snippet: string) {
  const offset = source.indexOf(snippet);
  assert.ok(offset >= 0, snippet);
  const lines = source.slice(0, offset).split(/\r\n|[\r\n\u2028\u2029]/u);
  return { line: lines.length, column: lines.at(-1)!.length };
}

function sourceMap(result: TransformResult) {
  const inline = /\n\/\/# sourceMappingURL=data:application\/json;base64,([A-Za-z0-9+/=]+)$/u.exec(
    result.code,
  );
  const encoded = inline ? Buffer.from(inline[1], "base64").toString("utf8") : result.map;
  assert.ok(encoded);
  if (inline && result.map) assert.deepEqual(JSON.parse(encoded), JSON.parse(result.map));
  return new TraceMap(encoded);
}

for (const separator of ["\u2028", "\u2029"])
  test(
    "Unicode separators preserve template mapping positions: " + JSON.stringify(separator),
    () => {
      const source = `<div>🦊${separator}<b>{__after}</b>${separator}<i>tail</i></div>`;
      const result = transform(source, { filename, sourcemap: "both" });
      assert.deepEqual(result.diagnostics, []);
      const map = sourceMap(result);
      const generated = result.code.split(/\r\n|[\r\n\u2028\u2029]/u);
      const original = source.split(/\r\n|[\r\n\u2028\u2029]/u);
      for (const [line, segments] of decodedMappings(map).entries())
        for (const segment of segments) {
          assert.ok(line < generated.length && segment[0] <= generated[line].length);
          if (segment.length === 1) continue;
          assert.ok(segment[2] < original.length && segment[3] <= original[segment[2]].length);
        }
      assert.deepEqual(originalPositionFor(map, position(result.code, "__after")), {
        source: filename,
        ...position(source, "{__after}"),
        name: null,
      });
    },
  );

for (const [name, source] of errorProbes)
  test("transform maps the actual thrown error to its source line: " + name, async () => {
    const result = transform(source, {
      filename,
      internalURL,
      sourcemap: "external",
      resolvePath: (specifier) => specifier,
    });
    assert.deepEqual(result.diagnostics, []);
    const module = await import(
      "data:text/javascript;base64," + Buffer.from(result.code).toString("base64")
    );
    let thrown: unknown;
    try {
      await container.renderToString(module.default);
    } catch (error) {
      thrown = error;
    }
    assert.ok(thrown instanceof Error);
    const frame = /data:text\/javascript;base64,[A-Za-z0-9+/=]+:(\d+):(\d+)/u.exec(
      thrown.stack ?? "",
    );
    assert.ok(frame, thrown.stack ?? thrown.message);
    const original = originalPositionFor(sourceMap(result), {
      line: Number(frame[1]),
      column: Number(frame[2]) - 1,
    });
    assert.strictEqual(original.source, filename);
    assert.strictEqual(original.line, position(source, "throw").line);
  });

for (const sourcemap of [undefined, "external", "inline", "both"] as const)
  test("resolved component paths preserve mappings in mode " + sourcemap, () => {
    const baseline = transform(pathSource, {
      filename,
      sourcemap,
      resolvePath: (specifier) => specifier,
    });
    for (const prefix of resolvedPaths) {
      const result = transform(pathSource, {
        filename,
        sourcemap,
        resolvePath: (specifier) => prefix + specifier,
      });
      assert.deepEqual(result.diagnostics, []);
      const file = ts.createSourceFile(
        "output.js",
        result.code,
        ts.ScriptTarget.Latest,
        true,
        ts.ScriptKind.JS,
      ) as ts.SourceFile & { parseDiagnostics: ts.Diagnostic[] };
      assert.deepEqual(file.parseDiagnostics, []);
      for (const component of result.hydratedComponents)
        assert.strictEqual(component.resolvedPath, prefix + component.specifier);
      const literals: string[] = [];
      function visit(node: ts.Node) {
        if (
          ts.isPropertyAssignment(node) &&
          ts.isStringLiteral(node.name) &&
          node.name.text === "client:component-path" &&
          ts.isStringLiteral(node.initializer)
        )
          literals.push(node.initializer.text);
        ts.forEachChild(node, visit);
      }
      visit(file);
      assert.deepEqual(literals, [prefix + "./C.jsx", prefix + "./D.jsx", prefix + "./C.jsx"]);
      if (sourcemap === undefined) {
        assert.strictEqual(result.map, "");
        continue;
      }
      if (sourcemap === "inline") assert.strictEqual(result.map, "");
      const map = sourceMap(result);
      assert.deepEqual(map.sourcesContent, [pathSource]);
      for (const marker of ["__first", "__second", "__third"]) {
        const original = originalPositionFor(map, position(result.code, marker));
        assert.deepEqual(
          original,
          originalPositionFor(sourceMap(baseline), position(baseline.code, marker)),
        );
        assert.deepEqual(original, {
          source: filename,
          ...position(pathSource, "{" + marker + "}"),
          name: null,
        });
      }
    }
  });

test("resolved paths preserve source-map-like text inside a template literal", () => {
  const source = pathSource.replace(
    "---\n",
    "---\nconst literal = `\n//# sourceMappingURL=data:application/json;base64,e30=`;\n",
  );
  const result = transform(source, {
    filename,
    sourcemap: "external",
    resolvePath: (specifier) => "/resolved/" + specifier,
  });
  assert.deepEqual(result.diagnostics, []);
  const file = ts.createSourceFile(
    "output.js",
    result.code,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.JS,
  ) as ts.SourceFile & { parseDiagnostics: ts.Diagnostic[] };
  assert.deepEqual(file.parseDiagnostics, []);
  assert.ok(result.code.includes("base64,e30="));
  const original = originalPositionFor(sourceMap(result), position(result.code, "__third"));
  assert.deepEqual(original, { source: filename, ...position(source, "{__third}"), name: null });
});

for (const newline of ["\n", "\r\n"])
  test("long template maps preserve UTF-16 columns and " + JSON.stringify(newline), () => {
    const source = [
      "<section>🦊日本語 " + "x".repeat(8192) + "{__first}",
      "  <span>é é 🦊{__second}</span>",
      "  {true ? <b>🦊{__third}</b> : <i>日本語</i>}",
      "</section>",
    ].join(newline);
    const result = transform(source, { filename, sourcemap: "external" });
    assert.deepEqual(result.diagnostics, []);
    const map = sourceMap(result);
    for (const marker of ["__first", "__second", "__third"])
      assert.deepEqual(originalPositionFor(map, position(result.code, marker)), {
        source: filename,
        ...position(source, "{" + marker + "}"),
        name: null,
      });
  });

test("source-map encoding preserves Unicode and the UTF-8 input normalization", () => {
  for (const text of ["🦊日本語 é", "\ud800", "\udc00", "\ud800\ud800", "\0"])
    for (const sourcemap of ["external", "inline", "both"] as const) {
      const source = "<p>" + text + "</p>";
      const result = transform(source, { filename, sourcemap });
      assert.deepEqual(result.diagnostics, []);
      assert.deepEqual(sourceMap(result).sourcesContent, [source.toWellFormed()]);
    }
});
