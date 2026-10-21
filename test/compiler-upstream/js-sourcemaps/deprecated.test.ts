// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { assert, describe, it } from "vite-plus/test";
import { testJSSourcemap } from "../utils.ts";

describe("js-sourcemaps/deprecated", () => {
  it("script is:inline", async () => {
    const input = `---
    /** @deprecated */
const deprecated = "Astro"
deprecated;
const hello = "Astro"
---
`;
    const output = await testJSSourcemap(input, "deprecated;");

    assert.deepStrictEqual(output, {
      source: "index.astro",
      line: 4,
      column: 0,
      name: null,
    });
  });
});
