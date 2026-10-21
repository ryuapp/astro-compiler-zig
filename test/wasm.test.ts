import { readFileSync } from "node:fs";
import { assert, test } from "vite-plus/test";
import { binding } from "./parse-internal.ts";
import { parse, convertToTsx, transform, preprocessStyles } from "../dist/index.mjs";

test("the bundled WASM runs without host imports", () => {
  const module = new WebAssembly.Module(
    readFileSync(new URL("../dist/compiler.wasm", import.meta.url)),
  );
  assert.deepEqual(WebAssembly.Module.imports(module), []);
});

test("WASM preserves unfinished UTF-16 strings and source copy mappings", () => {
  for (const text of ["🦊日本語", "\ud83e", "\udc00", "\ud800\ud800", "\0"]) {
    const result = convertToTsx("<p>" + text + "</p>", null);
    assert.ok(result.code.includes(text));
    for (const [start, length, original, originalLength, kind] of result.mappings)
      if (kind === 0)
        assert.strictEqual(
          result.code.slice(start, start + length),
          ("<p>" + text + "</p>").slice(original, original + originalLength),
        );
  }
});

test("WASM supports async style preprocessing followed by transform", async () => {
  const source = '<style lang="scss">$color:red;</style><style is:global>body{}</style>';
  const styles = await preprocessStyles(source, async (_content, attrs) =>
    attrs.lang === "scss" ? { code: "p{color:red}" } : { error: "failed" },
  );
  assert.deepEqual(styles, { styles: ["p{color:red}", ""], styleError: ["failed"] });
  const result = transform(source, { preprocessedStyles: styles, sourcemap: "both" });
  assert.deepEqual(result.css, [`p:where(.astro-${result.scope}){color:red}`]);
  assert.deepEqual(result.styleError, ["failed"]);
});

test("WASM arenas survive errors and retain owned results after memory grows", () => {
  const source = "---\nconst x=1;\n---\n<p>{x}</p>";
  const held = [parse(source), convertToTsx(source), transform(source)];
  const snapshot = structuredClone(held);
  assert.throws(() => binding.transform(source, '{"compact":42}'));
  const large = "<p>🦊</p>".repeat(12000);
  assert.deepEqual(parse(large).diagnostics, []);
  convertToTsx(large);
  transform(large);
  assert.deepEqual(held, snapshot);
  assert.deepEqual(parse(source), snapshot[0]);
});

test("WASM rejects invalid public arguments before entering the compiler", () => {
  for (const source of [undefined, null, 42, {}, []]) {
    assert.throws(() => Reflect.apply(parse, undefined, [source]), TypeError);
    assert.throws(() => Reflect.apply(convertToTsx, undefined, [source]), TypeError);
    assert.throws(() => Reflect.apply(transform, undefined, [source]), TypeError);
  }
  for (const options of [42, [], { filename: 42 }, { ambientTypes: "yes" }])
    assert.throws(() => Reflect.apply(convertToTsx, undefined, ["", options]), TypeError);
  for (const options of [42, [], "invalid"])
    assert.throws(() => Reflect.apply(transform, undefined, ["", options]), TypeError);
});
