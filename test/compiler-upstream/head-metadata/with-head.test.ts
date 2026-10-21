// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { type TransformResult, transform } from "../../../dist/index.mjs";
import { assert, beforeAll as before, describe, it } from "vite-plus/test";

const FIXTURE = `
<html>
  <head>
    <title>Testing</title>
  </head>
  <body>
    <h1>Testing</h1>
  </body>
</html>
`;

describe("head-metadata/with-head", () => {
  let result: TransformResult;
  before(async () => {
    result = await transform(FIXTURE, {
      filename: "test.astro",
    });
  });

  it("containsHead is true", () => {
    assert.deepStrictEqual(result.containsHead, true);
  });
});
