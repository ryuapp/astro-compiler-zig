// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { transform } from "../../../../dist/index.mjs";
import { assert, describe, it } from "vite-plus/test";

describe("scripts/isinline-hint", { skip: true }, () => {
  it("reports a hint for adding attributes to a script tag without is:inline", async () => {
    const result = await transform(`<script type="module"></script>`);
    assert.deepStrictEqual(result.diagnostics[0].severity, 4);
    assert.match(result.diagnostics[0].text, /\#script-processing/);
  });

  it("does not report a diagnostic for the src attribute", async () => {
    const result = await transform(`<script src="/external.js"></script>`);
    assert.deepStrictEqual(result.diagnostics.length, 0);
  });
});
