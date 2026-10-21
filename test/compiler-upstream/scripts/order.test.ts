// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { assert, describe, it } from "vite-plus/test";
import { transform } from "../../../dist/index.mjs";

describe("scripts/order", () => {
  it("outputs scripts in expected order", async () => {
    const result = await transform(
      `
    <script>console.log(1)</script>
    <script>console.log(2)</script>`,
    );

    const scripts = result.scripts;

    if (scripts[0].type === "external") throw new Error("Script is external");
    if (scripts[1].type === "external") throw new Error("Script is external");

    assert.ok(scripts[0].code);
    assert.ok(scripts[1].code);

    assert.ok(scripts[0].code.includes("console.log(1)"));
    assert.ok(scripts[1].code.includes("console.log(2)"));
  });
});
