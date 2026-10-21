// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { type TransformResult, transform } from "../../../../dist/index.mjs";
import { assert, beforeAll as before, describe, it } from "vite-plus/test";

const FIXTURE = `<html>
  <head>
    <title>Hello world</title>
  </head>
  <body>
    <div>
      <!--
    </div>
  </body>
</html>`;

describe("html-comment", { skip: true }, () => {
  let result: TransformResult;
  before(async () => {
    result = await transform(FIXTURE, {
      filename: "/src/components/EOF.astro",
    });
  });

  it("html comment error", () => {
    assert.ok(Array.isArray(result.diagnostics));
    assert.strictEqual(result.diagnostics.length, 1);
    assert.strictEqual(result.diagnostics[0].text, "Unterminated comment");
    assert.strictEqual(FIXTURE.split("\n")[result.diagnostics[0].location.line - 1], "      <!--");
  });
});
