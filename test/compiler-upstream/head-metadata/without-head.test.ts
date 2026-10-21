// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { type TransformResult, transform } from "../../../dist/index.mjs";
import { assert, beforeAll as before, describe, it } from "vite-plus/test";

const FIXTURE = `
<slot />
`;

describe("head-metadata/without-head", () => {
  let result: TransformResult;
  before(async () => {
    result = await transform(FIXTURE, {
      filename: "test.astro",
    });
  });

  it("containsHead is false", () => {
    assert.deepStrictEqual(result.containsHead, false);
  });
});
