import { assert, test } from "vite-plus/test";
import { transform } from "../dist/index.mjs";
import { transform as reference } from "@astrojs/compiler-rs";
import ts from "typescript-compat";

test("CDATA is rejected rather than emitted as an empty element", () => {
  const source = "<svg><![CDATA[a < b && c > d 🦊]]></svg>";
  const expected = reference(source, { sourcemap: "both" });
  const actual = transform(source, { sourcemap: "both" });
  assert.ok(expected.diagnostics.some((diagnostic) => diagnostic.severity === "error"));
  assert.ok(actual.diagnostics.some((diagnostic) => diagnostic.severity === "error"));
  assert.strictEqual(actual.code, expected.code);
  assert.strictEqual(actual.map, expected.map);
});

for (const newline of ["\n", "\r\n", "\r"]) {
  for (const expression of ["/[abc/;", "/[abc\\", "/abc\\"]) {
    test(
      "frontmatter regex errors survive closing fence " + JSON.stringify([newline, expression]),
      () => {
        const source = ["---", "const value=" + expression, "---", "<p>🦊</p>"].join(newline);
        const options = {
          filename: "/src/Regex.astro",
          sourcemap: "both" as const,
          resolvePath: (specifier: string) => specifier,
        };
        const expected = reference(source, options);
        const actual = transform(source, options);
        const shouldError = expression === "/[abc/;" || newline === "\r\n";
        assert.strictEqual(
          expected.diagnostics.some((diagnostic) => diagnostic.severity === "error"),
          shouldError,
        );
        assert.strictEqual(
          actual.diagnostics.some((diagnostic) => diagnostic.severity === "error"),
          shouldError,
        );
        if (shouldError) {
          assert.strictEqual(actual.code, expected.code);
          assert.strictEqual(actual.map, expected.map);
        } else {
          const print = (code: string) =>
            ts
              .createPrinter()
              .printFile(
                ts.createSourceFile(
                  "output.js",
                  code.split("//# sourceMappingURL=")[0],
                  ts.ScriptTarget.Latest,
                  true,
                  ts.ScriptKind.JS,
                ),
              );
          assert.strictEqual(print(actual.code), print(expected.code));
          const map = JSON.parse(actual.map);
          assert.deepEqual(map.sourcesContent, JSON.parse(expected.map).sourcesContent);
          const inline = actual.code.split("base64,").at(-1)!;
          assert.deepEqual(JSON.parse(Buffer.from(inline, "base64").toString()), map);
        }
      },
    );
  }
}
