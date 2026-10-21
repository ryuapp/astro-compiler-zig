// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { assert, describe, it } from "vite-plus/test";
import { testJSSourcemap } from "../utils.ts";

describe("js-sourcemaps/script", () => {
  it("script is:inline", async () => {
    const input = `<script is:inline>
  const MyNumber = 3;
  console.log(MyNumber.toStrang());
</script>
`;
    const output = await testJSSourcemap(input, "\n");

    assert.deepStrictEqual(output, {
      source: "index.astro",
      line: 1,
      column: 18,
      name: null,
    });
  });
});
