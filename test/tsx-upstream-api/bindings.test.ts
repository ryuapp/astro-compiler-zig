// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { assert, test } from "vite-plus/test";
import { AstroFrontmatterStatus, convertToTsx } from "../../dist/index.mjs";

test("reports frontmatter status and positioned diagnostics", () => {
  assert.strictEqual(
    convertToTsx("---\nlet x = 1;\n---\n<p/>").frontmatterStatus,
    AstroFrontmatterStatus.Closed,
  );
  assert.strictEqual(
    convertToTsx("---\nlet x = 1;\n").frontmatterStatus,
    AstroFrontmatterStatus.Open,
  );
  assert.strictEqual(convertToTsx("<p/>").frontmatterStatus, AstroFrontmatterStatus.DoesntExist);

  const broken = convertToTsx("<div>{x ==}</div>");
  assert.ok(broken.hasParseErrors);
  assert.ok(broken.diagnostics.length > 0);
  for (const diagnostic of broken.diagnostics) {
    assert.ok(diagnostic.message.length > 0);
    assert.strictEqual(diagnostic.severity, 1);
    assert.ok(diagnostic.position.end >= diagnostic.position.start);
  }
});
