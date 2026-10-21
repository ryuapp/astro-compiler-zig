import { assert, test as module0 } from "vite-plus/test";
import * as api from "../dist/index.mjs";
import inputs from "./fixtures/tsx-inputs.json" with { type: "json" };
import expected from "./fixtures/tsx-expected.json" with { type: "json" };
import probes from "./fixtures/parse-inputs.json" with { type: "json" };
import probeExpected from "./fixtures/tsx-probe-expected.json" with { type: "json" };
import { isYukuPending } from "./yuku-pending.ts";
const test = module0;
function checkRanges(source: string, result: any) {
  let previousEnd = 0;
  for (const [start, length, original, originalLength, kind] of result.mappings) {
    assert.ok(length > 0 && start >= previousEnd && start + length <= result.code.length);
    assert.ok(original >= 0 && originalLength >= 0 && original + originalLength <= source.length);
    previousEnd = start + length;
    if (kind === 0)
      assert.strictEqual(
        result.code.slice(start, start + length),
        source.slice(original, original + originalLength),
      );
  }
  for (const region of [result.frontmatter, result.body, result.generatedComponentExport].filter(
    Boolean,
  )) {
    assert.ok(region.start >= 0 && region.end >= region.start && region.end <= result.code.length);
  }
  for (const item of [...result.scripts, ...result.styles]) {
    assert.strictEqual(source.slice(item.position.start, item.position.end), item.content);
  }
  for (const item of result.diagnostics) {
    assert.ok(
      item.position.start >= 0 &&
        item.position.end >= item.position.start &&
        item.position.end <= source.length,
    );
    assert.ok(item.message.length && [1, 2, 3, 4].includes(item.severity));
  }
  assert.strictEqual(
    result.hasParseErrors,
    result.diagnostics.some((item: any) => item.severity === 1),
  );
}
for (const [index, input] of inputs.entries())
  test(`astro2tsx reference: ${input.name}`, () => {
    const { diagnostics, ...result } = api.convertToTsx(
      input.source,
      "options" in input
        ? (input.options as import("../src/types.ts").ConvertToTsxOptions)
        : undefined,
    );
    assert.strictEqual(expected.results[index].name, input.name);
    assert.deepEqual<unknown>(result, expected.results[index].expected);
    checkRanges(input.source, { ...result, diagnostics });
  });
// Reference span mappings also associate normalized tag names with their source spans.
// These grammar probes compare the captured public result without assuming verbatim text.
for (const [index, input] of probes.entries())
  test.skipIf(isYukuPending(input.source, "tsx"))(`astro2tsx grammar probe: ${input.name}`, () => {
    const { diagnostics, ...result } = api.convertToTsx(
      input.source,
      "options" in input
        ? (input.options as import("../src/types.ts").ConvertToTsxOptions)
        : undefined,
    );
    assert.strictEqual(probeExpected.results[index].name, input.name);
    assert.deepEqual<unknown>(result, probeExpected.results[index].expected);
    for (const [start, length, original, originalLength] of result.mappings) {
      assert.ok(start >= 0 && length >= 0 && start + length <= result.code.length);
      assert.ok(
        original >= 0 && originalLength >= 0 && original + originalLength <= input.source.length,
      );
    }
    assert.strictEqual(
      result.hasParseErrors,
      diagnostics.some((item) => item.severity === 1),
    );
  });
test("astro2tsx recovers across every prefix while retaining valid UTF-16 positions", () => {
  for (const source of [
    "---\ninterface Props<T extends string> { value: T }\nconst id = <T>(x: T) => x;\n---\n<Card label={Astro.props.value}>{items.map(x => <p>{x}</p>)}</Card>",
    "<style>.x{color:red}</style><script>const x: number = 42;</script><p onclick=\"go('🦊')\">こんにちは🦊</p>",
    "{enabled && <div @click={handler}><textarea><b>{value}</b></textarea><!-- note --></div>}",
  ])
    for (let end = 0; end <= source.length; end++) {
      const prefix = source.slice(0, end),
        result = api.convertToTsx(prefix);
      assert.ok(result.code.includes("export default function"));
      checkRanges(prefix, result);
    }
});
test("converter preserves the public Yuku parse result contract", () => {
  const source = "---\ninterface Props { name: string }\n---\n<p>{Astro.props.name}</p>";
  const before = Reflect.apply(api.parse, undefined, [source]);
  api.convertToTsx(source, { ambientTypes: true });
  assert.deepEqual(Reflect.apply(api.parse, undefined, [source]), before);
  assert.strictEqual(before.ast.frontmatter.program.type, "Program");
  assert.strictEqual(before.ast.frontmatter.program.body[0].type, "TSInterfaceDeclaration");
  const assertion = '---\nimport value from "./data.json" assert {type:"json"};\n---';
  assert.strictEqual(api.parse(assertion).diagnostics.length, 0);
  assert.strictEqual(api.convertToTsx(assertion).hasParseErrors, true);
});
test("editor diagnostic compatibility preserves strict Yuku diagnostics", () => {
  const source = "{a && b || c ?? d}";
  const before = Reflect.apply(api.parse, undefined, [source]);
  assert.ok(before.diagnostics.some((diagnostic) => diagnostic.severity === "error"));
  assert.strictEqual(Reflect.apply(api.convertToTsx, undefined, [source]).hasParseErrors, false);
  assert.deepEqual(Reflect.apply(api.parse, undefined, [source]), before);
  assert.strictEqual(api.convertToTsx("<p label={a + }/>").hasParseErrors, true);
});
test("converter input validation and module exports", async () => {
  assert.deepEqual(api.convertToTsx("", null), api.convertToTsx(""));
  for (const value of [undefined, null, 42, {}])
    assert.throws(() => Reflect.apply(api.convertToTsx, undefined, [value]), TypeError);
  for (const options of [42, [] as any[], { filename: 42 }, { ambientTypes: "yes" }])
    assert.throws(() => Reflect.apply(api.convertToTsx, undefined, ["", options]), TypeError);
  const esm = await import("../dist/index.mjs");
  assert.deepEqual(esm.convertToTsx("<p/>"), api.convertToTsx("<p/>"));
  assert.strictEqual(esm.AstroFrontmatterStatus.Closed, "closed");
});
