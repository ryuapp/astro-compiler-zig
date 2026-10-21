import { assert } from "vite-plus/test";
import type { ConvertToTsxResult } from "../src/types.ts";

export function normalizeDiagnostics(result: ConvertToTsxResult) {
  return {
    ...result,
    diagnostics: result.diagnostics.map(({ message: _message, ...diagnostic }) => diagnostic),
  };
}

/** Recovery suites allow partial JS trees to differ only when both implementations report errors. */
export function assertTsxCompatibility(
  source: string,
  actual: ConvertToTsxResult,
  expected: ConvertToTsxResult,
  allowErrorRecovery = false,
) {
  assert.strictEqual(actual.hasParseErrors, expected.hasParseErrors, source);
  if (!allowErrorRecovery || !expected.hasParseErrors) {
    assert.deepEqual(normalizeDiagnostics(actual), normalizeDiagnostics(expected), source);
    return;
  }
  // AST-dependent edits and diagnostic ranges are unspecified for invalid JS.
  // Extraction and mappings must still describe the original source accurately.
  assert.deepEqual(actual.scripts, expected.scripts, source);
  assert.deepEqual(actual.styles, expected.styles, source);
  assert.strictEqual(actual.frontmatterStatus, expected.frontmatterStatus, source);
  assert.deepEqual(actual.frontmatterSource, expected.frontmatterSource, source);
  assert.ok(
    actual.diagnostics.some(({ severity }) => severity === 1),
    source,
  );
  for (const { position } of actual.diagnostics)
    assert.ok(
      position.start >= 0 && position.end >= position.start && position.end <= source.length,
      source,
    );
  let previous = 0;
  for (const [start, length, original, originalLength, kind] of actual.mappings) {
    assert.ok(start >= previous && start + length <= actual.code.length, source);
    previous = start;
    assert.ok(original >= 0 && original + originalLength <= source.length, source);
    if (kind === 0)
      assert.strictEqual(
        actual.code.slice(start, start + length),
        source.slice(original, original + originalLength),
        source,
      );
  }
  for (const extracted of [...actual.scripts, ...actual.styles])
    assert.strictEqual(
      source.slice(extracted.position.start, extracted.position.end),
      extracted.content,
      source,
    );
}
