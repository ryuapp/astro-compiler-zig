import { assert, test, expectTypeOf } from "vite-plus/test";
import { pathToFileURL } from "node:url";
import path from "node:path";
import { SourceMap } from "node:module";
import {
  transform as rustTransform,
  type TransformOptions as RustTransformOptions,
} from "@astrojs/compiler-rs";
import * as api from "../dist/index.mjs";
import { canonicalCss } from "./css-compat.ts";
import ts from "typescript-compat";

test("transform emits an Astro runtime module with native CSS and script metadata", () => {
  const source =
    '---\nconst name: string = "world";\n---\n<html><head/><body><p>{name}</p></body></html><style>p { color:red }</style><script>const n:number=1;</script>';
  const result = api.transform(source, { filename: "/src/Page.astro", sourcemap: "external" });
  assert.deepEqual(result.diagnostics, [] as any[]);
  assert.strictEqual(result.containsHead, true);
  assert.strictEqual(result.propagation, false);
  assert.match(result.code, /astro\/runtime\/server\/index\.js/);
  assert.match(result.code, /export default \$\$Page/);
  assert.ok(!result.code.includes("name: string"));
  assert.match(result.css[0], new RegExp("p:where\\(\\.astro-" + result.scope + "\\)"));
  assert.deepEqual(result.scripts, [{ type: "inline", code: "const n: number = 1;" }]);
  const map = JSON.parse(result.map);
  assert.deepEqual(map.sources, ["/src/Page.astro"]);
  assert.deepEqual(map.sourcesContent, [source]);
  assert.strictEqual(map.version, 3);
  assert.ok(map.mappings.length);
});
test("hydration and server islands retain resolved import metadata", () => {
  const source =
    '---\nimport Counter from "./Counter.jsx";\nimport Private from "./Private.astro";\n---\n<Counter client:load/><Private server:defer/>';
  const result = api.transform(source, {
    filename: "/src/Page.astro",
    resolvePath: (s) => "/resolved/" + s.slice(2),
  });
  assert.deepEqual(result.hydratedComponents, [
    {
      exportName: "default",
      localName: "Counter",
      specifier: "./Counter.jsx",
      resolvedPath: "/resolved/Counter.jsx",
    },
  ]);
  assert.strictEqual(result.serverComponents[0].resolvedPath, "/resolved/Private.astro");
  assert.strictEqual(result.propagation, true);
  assert.ok(result.code.includes('"client:component-path": "/resolved/Counter.jsx"'));
  assert.ok(!result.code.includes("$$createMetadata"));
});
test("inline assets, caller-provided CSS and scope strategies use the same transform", () => {
  const result = api.transform('<p/>\n<style lang="scss">ignored</style>', {
    scopedStyleStrategy: "attribute",
    inlineComponentAssets: true,
    preprocessedStyles: { styles: ["p {color:blue}"], styleError: ["caller note"] },
  });
  assert.ok(result.css[0].includes("[data-astro-cid-" + result.scope + "]"));
  assert.ok(result.code.includes("<style>"));
  assert.ok(!result.code.includes("?astro&type=style"));
  assert.deepEqual(result.styleError, ["caller note"]);
});
test("scoped CSS treats selector comments as trivia", () => {
  const selectors = [
    "p /* note */",
    "p /* , > :global(.other) */",
    "p /* note */ .child",
    "p /* note */ > /* note */ .child",
    "p, /* note */ .child /* trailing */",
    ':global([data-initial]:not([role="tab"])) unit-progress-icon, /* 1 */\n' +
      ':global([aria-selected="true"]) unit-progress-icon /* 2 */',
  ];
  for (const scopedStyleStrategy of ["where", "class", "attribute"] as const) {
    for (const selector of selectors) {
      const source = `<p>text</p><style>${selector} { font-weight: bold }</style>`;
      const options = { filename: "SelectorComments.astro", scopedStyleStrategy };
      const result = api.transform(source, options);
      const expected = rustTransform(source, options);
      assert.deepEqual(result.diagnostics, []);
      assert.strictEqual(result.scope, expected.scope);
      assert.deepEqual(
        result.css.map(canonicalCss),
        expected.css.map(canonicalCss),
        `${scopedStyleStrategy}: ${selector}`,
      );
      assert.ok(result.css[0].endsWith(" { font-weight: bold }"));
    }
  }
});
test("scoped CSS handles comments within compounds and preserves attribute values", () => {
  for (const scopedStyleStrategy of ["where", "class", "attribute"] as const) {
    const selectors = [
      ["p/**/.child", "p$SCOPE.child"],
      ["p/* :global(.wrong), > */:hover", "p$SCOPE:hover"],
      ["p:hover/* ::before */", "p$SCOPE:hover/* ::before */"],
      [
        'p[data-note="/* :global(.wrong) ::before */"]',
        'p$SCOPE[data-note="/* :global(.wrong) ::before */"]',
      ],
      [':global([data-note=")"]) p', '[data-note=")"] p$SCOPE'],
      [String.raw`.escaped\:global\(x\)`, String.raw`.escaped\:global\(x\)$SCOPE`],
      ["body/**/.child", "body.child"],
      [":is(:global(.child))", "$SCOPE:is(.child)"],
      [":not(:global(.child))", "$SCOPE:not(.child)"],
      [
        ":global([data-initial]:not([role='tab'])) unit-progress-icon, /* 1 */\n" +
          ":global([aria-selected='true']) unit-progress-icon /* 2 */",
        "[data-initial]:not([role='tab']) unit-progress-icon$SCOPE, " +
          "[aria-selected='true'] unit-progress-icon$SCOPE /* 2 */",
      ],
    ];
    for (const [selector, expected] of selectors) {
      const result = api.transform(`<p/><style>${selector} { font-weight: bold }</style>`, {
        scopedStyleStrategy,
      });
      const suffix =
        scopedStyleStrategy === "where"
          ? `:where(.astro-${result.scope})`
          : scopedStyleStrategy === "class"
            ? `.astro-${result.scope}`
            : `[data-astro-cid-${result.scope}]`;
      assert.deepEqual(result.diagnostics, []);
      assert.deepEqual(result.css, [
        expected.replaceAll("$SCOPE", suffix) + " { font-weight: bold }",
      ]);
    }
  }
});
test("transform returns source diagnostics with byte ranges and positions", () => {
  const result = api.transform("🦊\n<div>{a + }</div>");
  assert.strictEqual(result.code, "");
  const error = result.diagnostics.find((d) => d.severity === "error");
  assert.ok(error);
  assert.ok(error.text.length);
  assert.strictEqual(typeof error.hint, "string");
  assert.ok(error.labels.length);
  assert.strictEqual(error.labels[0].line, 2);
  assert.ok(error.labels[0].start >= 5);
  assert.ok(error.labels[0].end >= error.labels[0].start);
});
test("transform source-map modes and Unicode keep original source content", () => {
  const source = '---\r\nconst name="🦊";\r\n---\r\n<p>{name}</p>';
  const inline = api.transform(source, { sourcemap: "inline" });
  const both = api.transform(source, { sourcemap: "both" });
  assert.strictEqual(inline.map, "");
  const encoded = inline.code.split("base64,")[1];
  assert.strictEqual(
    JSON.parse(Buffer.from(encoded, "base64").toString()).sourcesContent[0],
    source,
  );
  assert.strictEqual(JSON.parse(both.map).sourcesContent[0], source);
  assert.ok(both.code.includes("sourceMappingURL=data:"));
});
test("transform is available from the single ESM package entry", async () => {
  const module = await import(
    pathToFileURL(path.resolve(import.meta.dirname, "../dist/index.mjs")).href
  );
  assert.strictEqual(typeof module.transform, "function");
  assert.deepEqual(module.transform("<p/>"), api.transform("<p/>"));
});
test("transform rejects invalid argument types", () => {
  for (const source of [undefined, null, 42, {}, [] as any[]])
    assert.throws(() => Reflect.apply(api.transform, undefined, [source]), TypeError);
  for (const options of [42, "x", [] as any[]])
    assert.throws(() => Reflect.apply(api.transform, undefined, ["", options]), TypeError);
});

test("transform maps public options like compiler-rs without binding-only extensions", () => {
  expectTypeOf<api.TransformOptions>().toEqualTypeOf<RustTransformOptions>();
  const source =
    '---\nimport Card from "./Card.astro";\n---\n<p>  <a href="#">  <code>foo</code></a> bar</p><Card><!-- slot comment --><p> a   b </p></Card>';
  for (const transform of [api.transform, rustTransform]) {
    const uncompressed = transform(source, { compact: false });
    assert.notStrictEqual(transform(source, { compact: true }).code, uncompressed.code);
    for (const compact of ["none", "html"])
      assert.deepEqual(Reflect.apply(transform, undefined, [source, { compact }]), uncompressed);
    for (const sourcemap of [true, false])
      assert.throws(() => Reflect.apply(transform, undefined, [source, { sourcemap }]));
    assert.deepEqual(transform(source, { stripSlotComments: false }), transform(source));
  }
});
function printScript(code: string) {
  const tree = ts.createSourceFile(
    "script.ts",
    code,
    ts.ScriptTarget.Latest,
    true,
    ts.ScriptKind.TS,
  );
  return ts.createPrinter({ newLine: ts.NewLineKind.LineFeed }).printFile(tree);
}

test("root inline script trivia preserves automatic head rendering order", () => {
  const source = '<script is:inline src="/x.js"/><!--🦊--><p>x</p>';
  const options = {
    filename: "/src/InlineScript.astro",
    sourcemap: "both" as const,
    resolvePath: (specifier: string) => specifier,
  };
  const result = api.transform(source, options);
  const expected = rustTransform(source, options);
  assert.deepEqual(result.diagnostics, []);
  assert.strictEqual(
    printScript(result.code.split("//# sourceMappingURL=")[0]),
    printScript(expected.code.split("//# sourceMappingURL=")[0]),
  );
  assert.deepEqual(JSON.parse(result.map).sourcesContent, [source]);
});

test("hoisted scripts preserve runtime TypeScript for the host bundler", async () => {
  const source =
    "---\nenum Outer {Value=10}\n---\n<p>{Outer.Value}</p><script>enum Flag {A=2,B}; export const value=Flag.B;</script>";
  const result = Reflect.apply(api.transform, undefined, [source]);
  assert.deepEqual(result.diagnostics, [] as any[]);
  assert.strictEqual(result.scripts.length, 1);
  assert.strictEqual(
    printScript(result.scripts[0].code!),
    printScript(rustTransform(source).scripts[0].code!),
  );
  const compiled = ts.transpileModule(result.scripts[0].code!, {
    compilerOptions: { target: ts.ScriptTarget.ESNext, module: ts.ModuleKind.ESNext },
  });
  const script = await import(
    "data:text/javascript;base64," + Buffer.from(compiled.outputText).toString("base64")
  );
  assert.strictEqual(script.value, 3);
  assert.ok(result.code.includes("Outer"));
});

test("extracted scripts retain types and comments without borrowing other script regions", () => {
  const source = [
    "---\r\n// frontmatter only\r\nconst title: string = '🦊';\r\n---\r\n",
    "<p>{title}</p><script>// first script\r\nimport type { Options } from './types';\r\ninterface State { value: string }\r\ntype Name = keyof State;\r\nexport const state = {value: '🦊'} satisfies State;\r\nexport function read<T extends State>(value: T): string { return value.value; }</script>",
    "<script>// second script\r\nnamespace Store { export const value: number = 2; }\r\nexport const result = Store.value as number;</script>",
  ].join("");
  const actual = api.transform(source);
  const expected = rustTransform(source);
  assert.deepEqual(actual.diagnostics, []);
  assert.strictEqual(actual.scripts.length, 2);
  for (const [index, script] of actual.scripts.entries()) {
    assert.strictEqual(script.type, expected.scripts[index].type);
    assert.strictEqual(printScript(script.code!), printScript(expected.scripts[index].code!));
    assert.ok(!script.code!.includes("frontmatter only"));
    assert.ok(!script.code!.includes(index === 0 ? "second script" : "first script"));
  }
});

test("only renderable elements and components receive CSS scope markers", () => {
  for (const name of [
    "Fragment",
    "base",
    "basefont",
    "bgsound",
    "font",
    "frame",
    "frameset",
    "head",
    "link",
    "meta",
    "noframes",
    "noscript",
    "slot",
    "title",
    "div",
    "Card",
  ]) {
    for (const scopedStyleStrategy of ["attribute", "class", "where"] as const) {
      const source = `<${name}/><style>p{color:red}</style>`;
      const options = { scopedStyleStrategy };
      const actual = api.transform(source, options);
      const expected = rustTransform(source, options);
      assert.deepEqual(actual.diagnostics, []);
      const marker =
        scopedStyleStrategy === "attribute"
          ? "data-astro-cid-" + actual.scope
          : "astro-" + actual.scope;
      assert.strictEqual(
        actual.code.includes(marker),
        expected.code.includes(marker),
        name + ": " + scopedStyleStrategy,
      );
    }
  }
});

test("transform preserves Astro import assertions without rewriting string contents", () => {
  for (const keyword of ["assert", "with"]) {
    const source = `---\nimport data, { with as other } from "./data.json" ${keyword} { type: "json" };\nconst literal = " with {";\n---\n<p>{data.value}{other}{literal}</p>`;
    const result = api.transform(source, { sourcemap: "external" });
    assert.deepEqual(result.diagnostics, []);
    assert.match(result.code, /from "\.\/data\.json" assert \{ type: "json" \}/);
    assert.ok(result.code.includes("with as other"));
    assert.ok(result.code.includes('" with {"'));
    const map = JSON.parse(result.map);
    assert.deepEqual(map.sourcesContent, [source]);
    const lines = result.code.split("\n");
    const line = lines.findIndex((value) => value.startsWith("import data,"));
    assert.ok(line >= 0);
    const position = new SourceMap(map).findEntry(line, lines[line].indexOf('"json"'));
    assert.ok(
      "originalLine" in position && "originalColumn" in position && "generatedColumn" in position,
    );
    assert.strictEqual(position.originalLine, 1);
    assert.strictEqual(position.originalColumn, 0);
    assert.strictEqual(position.generatedColumn, lines[line].indexOf('"json"'));
  }
});
