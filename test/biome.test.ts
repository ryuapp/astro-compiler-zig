// SPDX-License-Identifier: MIT
// Copyright (c) 2023-present Biome Developers and Contributors.
// Copyright (c) 2020-2023 Rome Tools is Rome Tools, Inc. and its affiliates.
// Fixture provenance and diagnostic adaptations are recorded in fixtures/biome/origin.json.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { assert, test } from "vite-plus/test";
import { parse as referenceParse } from "@astrojs/compiler-rs";
import { parse, convertToTsx } from "../dist/index.mjs";
import { assertSyntax, assertVerbatim, assertReference } from "./tsx-upstream/helpers.ts";
import origin from "./fixtures/biome/origin.json" with { type: "json" };

const directory = join(import.meta.dirname, "fixtures/biome");
function checkRange(start: number, end: number, length: number) {
  assert.ok(Number.isInteger(start) && Number.isInteger(end));
  assert.ok(start >= 0 && start <= end && end <= length, JSON.stringify({ start, end, length }));
}
for (const fixture of origin.fixtures) {
  const original = readFileSync(join(directory, fixture.file), "utf8");
  const source =
    fixture.kind === "expression"
      ? origin.expressionWrapper.prefix + original + origin.expressionWrapper.suffix
      : original;
  test("Biome parse: " + fixture.file, () => {
    if ("parseThrows" in fixture) {
      assert.strictEqual(fixture.parseThrows, "SyntaxError");
      assert.throws(() => referenceParse(source), SyntaxError);
      assert.throws(() => parse(source), SyntaxError);
      return;
    }
    const result = parse(source);
    assert.strictEqual(
      result.diagnostics.some((diagnostic) => diagnostic.severity === "error"),
      fixture.parseErrors,
      JSON.stringify(result.diagnostics),
    );
    if ("diagnosticDifference" in fixture)
      assert.strictEqual(
        referenceParse(source).diagnostics.some((diagnostic) => diagnostic.severity === "error"),
        fixture.parseErrors,
        fixture.diagnosticDifference ?? fixture.file,
      );
    const { ast } = result;
    assert.strictEqual(ast.type, "AstroRoot");
    assert.strictEqual(ast.start, 0);
    assert.strictEqual(ast.end, source.length);
    const pending: unknown[] = [ast];
    while (pending.length) {
      const value = pending.pop();
      if (Array.isArray(value)) pending.push(...value);
      else if (value && typeof value === "object") {
        const node = value as Record<string, any>;
        if (typeof node.start === "number" && typeof node.end === "number")
          checkRange(node.start, node.end, source.length);
        pending.push(...Object.values(node));
      }
    }
    for (const diagnostic of result.diagnostics) assert.ok(diagnostic.text.length > 0);
  });

  test("Biome TSX: " + fixture.file, () => {
    const options = { filename: fixture.file.split("/").at(-1)! };
    const result = convertToTsx(source, options);
    assert.strictEqual(
      result.hasParseErrors,
      fixture.tsxErrors,
      JSON.stringify(result.diagnostics),
    );
    assertVerbatim(source, result);
    if ("tsxDiagnosticDifference" in fixture) assertReference(source, options);
    else if (!result.hasParseErrors) assertSyntax(result.code);
    else assert.ok(result.diagnostics.some((diagnostic) => diagnostic.severity === 1));
    for (const range of [result.frontmatter, result.body, result.generatedComponentExport]) {
      if (range) checkRange(range.start, range.end, result.code.length);
    }
    checkRange(result.frontmatterSource.start, result.frontmatterSource.end, source.length);
    for (const extracted of [...result.scripts, ...result.styles]) {
      checkRange(extracted.position.start, extracted.position.end, source.length);
      if (extracted.type !== "event-attribute" && extracted.type !== "style-attribute")
        assert.strictEqual(
          source.slice(extracted.position.start, extracted.position.end),
          extracted.content,
        );
    }
    for (const diagnostic of result.diagnostics)
      checkRange(diagnostic.position.start, diagnostic.position.end, source.length);
  });
}
