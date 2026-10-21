// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { assert, test } from "vite-plus/test";
import {
  AstroFrontmatterStatus,
  convertToTsx,
  DiagnosticSeverity,
  ExtractedScriptType,
  ExtractedStyleType,
} from "../../dist/index.mjs";

test("exports enums and converts extracted tag metadata", () => {
  const result = convertToTsx("<script>const x = 1;</script><style>.x { color: red }</style>");

  assert.strictEqual(AstroFrontmatterStatus.Closed, "closed");
  assert.strictEqual(DiagnosticSeverity.Error, 1);
  assert.strictEqual(ExtractedScriptType.ProcessedModule, "processed-module");
  assert.strictEqual(ExtractedStyleType.Tag, "tag");
  const [script] = result.scripts;
  const [style] = result.styles;
  assert.ok(script);
  assert.ok(style);
  assert.strictEqual(script.type, ExtractedScriptType.ProcessedModule);
  assert.strictEqual(style.type, ExtractedStyleType.Tag);
});
