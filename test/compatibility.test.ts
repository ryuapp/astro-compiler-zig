import { assert, test as module1 } from "vite-plus/test";
import { parse } from "../dist/index.mjs";
import jsonFixture from "./fixtures/compiler-rs-syntax.json" with { type: "json" };
import { isYukuPending } from "./yuku-pending.ts";
const { fixtures } = jsonFixture;
const test = module1;
for (const fixture of fixtures) {
  test.skipIf(isYukuPending(fixture.source, "syntax"))(
    `compiler-rs syntax: ${fixture.name}`,
    () => {
      const result = parse(fixture.source);
      assert.strictEqual(
        result.diagnostics.some((diagnostic) => diagnostic.severity === "error"),
        fixture.hasErrors,
      );
      assert.strictEqual(result.ast.type, "AstroRoot");
      assert.strictEqual(result.ast.end, fixture.source.length);
    },
  );
}
test("parse accepts only source strings", () => {
  for (const source of [undefined, null, 1, {}, [] as any[]])
    assert.throws(() => Reflect.apply(parse, undefined, [source]), TypeError);
});
