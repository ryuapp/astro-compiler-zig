// Ported from withastro/compiler-rs astro2tsx at the revision in fixtures/tsx-upstream/origin.json.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { assert, test } from "vite-plus/test";
import ts from "typescript-compat";
import { convertToTsx } from "../../dist/index.mjs";
import { binding } from "../parse-internal.ts";
import type { ConvertToTsxOptions, ConvertToTsxResult } from "../../src/types.ts";
import origin from "../fixtures/tsx-upstream/origin.json" with { type: "json" };
import { convertToTsx as reference } from "@astrojs/astro2tsx";

assert.strictEqual(
  typeof binding.convertToTsx,
  "function",
  "Upstream tests must exercise WASM TSX",
);
export { assert, ts };
export const registered = new Set<string>();
export function upstream(file: string, name: string, body: () => void) {
  const id = file + ":" + name;
  assert.ok(
    origin.tests.some((item) => item.id === id && item.runner === "vitest"),
    id,
  );
  assert.ok(!registered.has(id), "Duplicate upstream test: " + id);
  registered.add(id);
  test(id, body);
}
export function convert(source: string, options?: ConvertToTsxOptions): ConvertToTsxResult {
  return convertToTsx(source, options);
}
export function assertReference(source: string, options?: ConvertToTsxOptions) {
  const normalize = (result: ConvertToTsxResult) => ({
    ...result,
    diagnostics: result.diagnostics.map((diagnostic) =>
      Object.fromEntries(Object.entries(diagnostic).filter(([key]) => key !== "message")),
    ),
  });
  assert.deepEqual(normalize(convert(source, options)), normalize(reference(source, options)));
}
export function assertSyntax(code: string) {
  const tree = ts.createSourceFile(
    "output.tsx",
    code,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TSX,
  ) as ts.SourceFile & { parseDiagnostics: ts.Diagnostic[] };
  assert.deepEqual(
    tree.parseDiagnostics.map((item) => ts.flattenDiagnosticMessageText(item.messageText, "\n")),
    [],
    code,
  );
}
export function assertVerbatim(source: string, result: ConvertToTsxResult) {
  let previous = 0;
  for (const [start, length, original, originalLength, kind] of result.mappings) {
    assert.ok(start >= previous && start + length <= result.code.length);
    previous = start;
    if (kind !== 0) continue;
    assert.ok(original >= 0 && original + originalLength <= source.length);
    assert.strictEqual(
      result.code.slice(start, start + length),
      source.slice(original, original + originalLength),
      source,
    );
  }
}
export function clean(source: string, options?: ConvertToTsxOptions) {
  const result = convert(source, options);
  assert.strictEqual(
    result.hasParseErrors,
    false,
    JSON.stringify({ source, diagnostics: result.diagnostics }),
  );
  assertSyntax(result.code);
  assertVerbatim(source, result);
  return result;
}
export function contains(code: string, value: string) {
  assert.ok(code.includes(value), JSON.stringify(value) + " missing from:\n" + code);
}
export function absent(code: string, value: string) {
  assert.ok(!code.includes(value), JSON.stringify(value) + " unexpectedly present in:\n" + code);
}
export function slice(code: string, range: { start: number; end: number }) {
  return code.slice(range.start, range.end);
}
export function assertMapped(source: string, snippets: string[]) {
  const result = convert(source);
  assert.strictEqual(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
  for (const snippet of snippets) {
    const start = source.indexOf(snippet);
    assert.ok(start >= 0, snippet);
    let offset = 0;
    for (const character of snippet) {
      const original = start + offset;
      const mapping = result.mappings.find(
        ([, length, from, , kind]) =>
          kind === 0 && original >= from && original + character.length <= from + length,
      );
      assert.ok(mapping, snippet + " at " + original + " is unmapped in " + source);
      const generated = mapping[0] + original - mapping[2];
      assert.strictEqual(result.code.slice(generated, generated + character.length), character);
      const reverse = result.mappings.findLast(([start]) => start <= generated);
      assert.ok(reverse && reverse[4] === 0);
      assert.strictEqual(reverse[2] + generated - reverse[0], original);
      offset += character.length;
    }
  }
}
export const fixtureDirectory = join(import.meta.dirname, "../fixtures/tsx-upstream/fixtures");
export function fixture(name: string) {
  let source = readFileSync(join(fixtureDirectory, name), "utf8");
  const options: ConvertToTsxOptions = {};
  while (source.startsWith("// @config ")) {
    const newline = source.indexOf("\n");
    const line = source.slice(0, newline < 0 ? source.length : newline).trimEnd();
    if (line.startsWith("// @config filename="))
      options.filename = line.slice("// @config filename=".length).trim();
    source = newline < 0 ? "" : source.slice(newline + 1);
  }
  return { source, options };
}
