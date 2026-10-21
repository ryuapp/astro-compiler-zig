// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { transform } from "../../../../dist/index.mjs";
import { assert, describe, it } from "vite-plus/test";

const FIXTURE = `
<div data-astro-reload>
  <a href="/" data-astro-reload>/</a>
  <form data-astro-reload="x">.</form>
  <area data-astro-reload/>
  <svg xmlns="http://www.w3.org/2000/svg"><a data-astro-reload>.</a></svg>
  <script is:inline data-astro-rerun src="some.js" type="module" />
  <script is:inline data-astro-rerun>"Bar"</script>
</div>`;

describe("transition/data-astro", { skip: true }, () => {
  it("Issues warnings for data-astro-* attributes", async () => {
    const result = await transform(FIXTURE);
    assert.deepStrictEqual(result.diagnostics.length, 2);
    assert.deepStrictEqual(result.diagnostics[0].code, 2000);
    assert.deepStrictEqual(result.diagnostics[1].code, 2010);
  });
});
