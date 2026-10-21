// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { type TransformResult, transform } from "../../../dist/index.mjs";
import { assert, describe, it, beforeAll as before } from "vite-plus/test";

const FIXTURE = `
---
import Parent from './Parent.astro';
---
<Parent>
  <div></div>
</Parent>
`;

let result: TransformResult;

describe("slot-result/result", () => {
  before(async () => {
    result = await transform(FIXTURE, {
      resolvePath: (s) => s,
      resultScopedSlot: true,
    });
  });

  it("resultScopedSlot: includes the result object in the call to the slot", () => {
    assert.match(result.code, /\(\$\$result\) =>/);
  });
});
