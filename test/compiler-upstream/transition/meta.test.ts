// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { type TransformResult, transform } from "../../../dist/index.mjs";
import { assert, describe, it, beforeAll as before } from "vite-plus/test";

const FIXTURE = `
<div transition:animate="slide"></div>
`;

let result: TransformResult;

describe("transition/meta", () => {
  before(async () => {
    result = transform(FIXTURE, {
      resolvePath: (s) => s,
    });
  });

  it("tagged with propagation metadata", () => {
    assert.deepStrictEqual(result.propagation, true);
  });
});
