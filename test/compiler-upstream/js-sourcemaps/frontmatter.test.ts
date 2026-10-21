// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { assert, describe, it } from "vite-plus/test";
import { testJSSourcemap } from "../utils.ts";

describe("js-sourcemaps/frontmatter", () => {
  it("frontmatter", async () => {
    const input = `---
nonexistent
---
`;
    const output = await testJSSourcemap(input, "nonexistent");

    assert.deepStrictEqual(output, {
      source: "index.astro",
      line: 2,
      column: 0,
      name: null,
    });
  });
});
