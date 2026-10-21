// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { assert, test } from "vite-plus/test";
import ts from "typescript-compat";
import { convertToTsx } from "../../dist/index.mjs";

test("event extraction covers TypeScript DOM event handler interfaces", () => {
  const lib = join(dirname(ts.getDefaultLibFilePath({})), "lib.dom.d.ts");
  const dom = ts.createSourceFile(lib, readFileSync(lib, "utf8"), ts.ScriptTarget.Latest, true);
  const interfaces = new Set([
    "GlobalEventHandlers",
    "WindowEventHandlers",
    "DocumentAndElementEventHandlers",
  ]);
  for (const statement of dom.statements) {
    if (!ts.isInterfaceDeclaration(statement) || !interfaces.has(statement.name.text)) continue;
    for (const member of statement.members) {
      const name = member.name?.getText(dom);
      if (!name?.startsWith("on")) continue;
      const result = convertToTsx(`<div ${name}="handler(event)" />`);
      assert.strictEqual(result.scripts[0]?.content, "handler(event)", name);
    }
  }
});
