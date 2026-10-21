// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { type TransformResult, transform } from "../../../dist/index.mjs";
import { assert, describe, it, beforeAll as before } from "vite-plus/test";

const FIXTURE = `
---
let value = 'world';
---

<style>div { color: red; }</style>

<div>Hello world!</div>
`;

let result: TransformResult;

describe("styles/emit-scope", () => {
  before(async () => {
    result = await transform(FIXTURE, {
      sourcemap: "external",
    });
  });

  it("emits a scope", () => {
    assert.ok(result.scope, "Expected to return a scope");
  });
});
