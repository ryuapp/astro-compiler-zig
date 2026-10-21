// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { assert, test } from "vite-plus/test";
import { convertToTsx } from "../../dist/index.mjs";

test("public diagnostic ranges stay within UTF-16 source boundaries", () => {
  for (const input of ["   ---\n`t a=1", "---\nconst text = `𝒳${value}`;\n---\n<C @x={text} />"]) {
    let source = "";
    for (const character of input) {
      source += character;
      const result = convertToTsx(source);
      for (const { position } of result.diagnostics) {
        assert.ok(0 <= position.start && position.start <= position.end);
        assert.ok(position.end <= source.length, JSON.stringify({ source, position }));
      }
    }
  }
});
