// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { type TransformResult, transform } from "../../../dist/index.mjs";
import { assert, describe, it, beforeAll as before } from "vite-plus/test";

const FIXTURE = `
---
---
<style>
    .thing { color: green; }
    .url-space { background: url('/white space.png'); }
    .escape:not(#\\#) { color: red; }
</style>
`;

describe("static-extraction/css", () => {
  let result: TransformResult;
  before(async () => {
    result = await transform(FIXTURE);
  });

  it("extracts styles", () => {
    assert.deepStrictEqual(
      result.css.length,
      1,
      `Incorrect CSS returned. Expected a length of 1 and got ${result.css.length}`,
    );
  });

  it("escape url with space", () => {
    assert.ok(result.css[0].includes("background: url('/white space.png')"));
  });

  it("escape css syntax", () => {
    assert.ok(result.css[0].includes(":not(#\\#)"));
  });
});
