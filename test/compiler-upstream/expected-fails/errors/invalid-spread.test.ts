// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { transform } from "../../../../dist/index.mjs";
import { assert, describe, it } from "vite-plus/test";

describe("invalid-spread", { skip: true }, () => {
  it("...spread has warning", async () => {
    const result = await transform("<Head ...seo />", { filename: "/src/components/Foo.astro" });
    assert.ok(Array.isArray(result.diagnostics));
    assert.strictEqual(result.diagnostics.length, 1);
    assert.strictEqual(result.diagnostics[0].code, 2008);
  });

  it("{...spread} does not have warning", async () => {
    const result = await transform("<Head {...seo} />", { filename: "/src/components/Foo.astro" });
    assert.ok(Array.isArray(result.diagnostics));
    assert.strictEqual(result.diagnostics.length, 0);
  });
});
