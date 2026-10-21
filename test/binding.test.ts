import { assert, test as module0 } from "vite-plus/test";
import { binding } from "./parse-internal.ts";
const test = module0;
test("binding TSX preserves original UTF-16 units and their copy mappings", () => {
  assert.strictEqual(typeof binding.convertToTsx, "function");
  for (const value of ["🦊日本語", "\ud83e", "\udc00"]) {
    const source = "<p>" + value + "</p>";
    const result = binding.convertToTsx(source, { filename: "Panel.astro" });
    assert.ok(result.code.includes(value));
    for (const [start, length, original, originalLength, kind] of result.mappings) {
      if (kind === 0)
        assert.strictEqual(
          result.code.slice(start, start + length),
          source.slice(original, original + originalLength),
        );
    }
  }
});
test("binding TSX validates arguments without relying on the JS wrapper", () => {
  for (const source of [undefined, null, 42, {}])
    assert.throws(() => Reflect.apply(binding.convertToTsx, undefined, [source]), TypeError);
  for (const options of [42, [] as any[], { filename: 42 }, { ambientTypes: "yes" }])
    assert.throws(() => Reflect.apply(binding.convertToTsx, undefined, ["", options]), TypeError);
  assert.deepEqual(binding.convertToTsx("", null), binding.convertToTsx(""));
});
test("binding TSX results retain owned strings and mappings after later document arenas are freed", () => {
  const source = "---\ninterface Props<T> { name: T }\n---\n<Card title={Astro.props.name}/>";
  const result = binding.convertToTsx(source, { filename: "Panel.astro", ambientTypes: true });
  const snapshot = JSON.stringify(result);
  for (let index = 0; index < 100; index++) binding.convertToTsx("<p>{" + index + "}</p>");
  assert.strictEqual(JSON.stringify(result), snapshot);
});

test("WASM storage survives reentrant and throwing TSX option getters", () => {
  const source = "---\nconst title = 'outer';\n---\n<Card title={title}/>";
  const options = { filename: "Outer.astro", ambientTypes: true };
  const expected = binding.convertToTsx(source, options);
  const nested = "<div>" + "<p>{1 + 2}</p>".repeat(1000) + "</div>";
  const result = binding.convertToTsx(source, {
    get filename() {
      binding.parseBuffer(nested);
      binding.convertToTsx(nested, { filename: "Inner.astro" });
      return options.filename;
    },
    get ambientTypes() {
      binding.transform(nested, JSON.stringify({ sourcemap: "both" }));
      return options.ambientTypes;
    },
  });
  assert.deepEqual(result, expected);
  assert.throws(
    () =>
      binding.convertToTsx(source, {
        get filename(): string {
          binding.parseBuffer(nested);
          throw new Error("option getter failed");
        },
      }),
    /option getter failed/,
  );
  assert.deepEqual(binding.convertToTsx(source, options), expected);
});
