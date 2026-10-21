import { canonicalCss } from "./css-compat.ts";
import { readFileSync } from "node:fs";
import { compileString } from "sass";
import { assert, test, expectTypeOf } from "vite-plus/test";
import {
  preprocessStyles as rustPreprocess,
  transform as rustTransform,
} from "@astrojs/compiler-rs";
import { preprocessStyles, transform, parse } from "../dist/index.mjs";
import type { PreprocessedStyles, PreprocessorResult } from "../src/types.ts";
import { styleInputs, generatedStyleInputs } from "./fixtures/preprocess-style-inputs.ts";
import { fixtures } from "./fixtures/compiler-rs-syntax.json" with { type: "json" };

for (const { name, source } of [...styleInputs, ...fixtures])
  test("style extraction matches official Rust: " + name, () => {
    const actual: { content: string; attrs: Record<string, string> }[] = [];
    const expected: typeof actual = [];
    const result = preprocessStyles(source, (content, attrs) => {
      actual.push({ content, attrs });
      return { code: content };
    });
    const reference = rustPreprocess(source, (content, attrs) => {
      expected.push({ content, attrs });
      return { code: content };
    });
    assert.deepEqual(actual, expected);
    assert.deepEqual(result, reference);
  });

test("sync results retain indices for skipped, failed and empty styles", () => {
  expectTypeOf(preprocessStyles).toEqualTypeOf<typeof rustPreprocess>();
  const source = "<style>a{}</style><style>b{}</style><style>c{}</style><style>d{}</style>";
  const result = preprocessStyles(source, (content) => {
    if (content === "a{}") return null;
    if (content === "b{}") return { error: "could not preprocess" };
    if (content === "c{}") return { code: "", map: "ignored CSS map" };
    return { code: "p{color:blue}" };
  });
  expectTypeOf(result).toEqualTypeOf<PreprocessedStyles>();
  assert.deepEqual(result, {
    styles: [undefined, "", "", "p{color:blue}"],
    styleError: ["could not preprocess"],
  });
  const compiled = transform(source, { preprocessedStyles: result });
  assert.strictEqual(compiled.css.length, 2);
  assert.match(compiled.css[0], /^a/);
  assert.deepEqual(
    compiled.css.map(canonicalCss),
    rustTransform(source, { preprocessedStyles: result }).css.map(canonicalCss),
  );
  assert.deepEqual(compiled.styleError, result.styleError);
});

test("style extraction matches official across generated attributes, bodies and nesting contexts", () => {
  for (const { name, source } of generatedStyleInputs()) {
    const actual: { content: string; attrs: Record<string, string> }[] = [];
    const expected: typeof actual = [];
    assert.deepEqual(
      preprocessStyles(source, (content, attrs) => {
        actual.push({ content, attrs });
        return { code: content };
      }),
      rustPreprocess(source, (content, attrs) => {
        expected.push({ content, attrs });
        return { code: content };
      }),
      name,
    );
    assert.deepEqual(actual, expected, name);
  }
});

test("all callbacks run when a synchronous preprocessor throws", () => {
  let index = 0;
  const result = preprocessStyles("<style>a</style><style>b</style><style>c</style>", () => {
    if (index++ === 0) throw new Error("first");
    if (index === 2) throw "second";
    return null;
  });
  assert.strictEqual(index, 3);
  assert.deepEqual(result, { styles: ["", "", undefined], styleError: ["first", "second"] });
});

test("async callbacks start in document order and results stay ordered when resolved in reverse", async () => {
  const callbacks: string[] = [];
  const resolvers: ((result: PreprocessorResult) => void)[] = [];
  const result = preprocessStyles("<style>a</style><style>b</style><style>c</style>", (content) => {
    callbacks.push(content);
    return new Promise<PreprocessorResult>((resolve) => resolvers.push(resolve));
  });
  expectTypeOf(result).toEqualTypeOf<Promise<PreprocessedStyles>>();
  assert.deepEqual(callbacks, ["a", "b", "c"]);
  resolvers[2]({ code: "third" });
  resolvers[1]({ code: "second" });
  resolvers[0]({ code: "first" });
  assert.deepEqual(await result, { styles: ["first", "second", "third"], styleError: [] });
});

test("mixed callbacks collect throws, rejections and explicit errors in document order", async () => {
  const source = "<style>a</style><style>b</style><style>c</style><style>d</style><style>e</style>";
  function callback(content: string) {
    if (content === "a") return { code: "sync" };
    if (content === "b") return Promise.reject(new Error("rejected"));
    if (content === "c") throw new Error("thrown");
    if (content === "d") return Promise.resolve({ error: "explicit error" });
    return Promise.resolve(null);
  }
  assert.deepEqual(
    await Reflect.apply(preprocessStyles, undefined, [source, callback]),
    await Reflect.apply(rustPreprocess, undefined, [source, callback]),
  );
  assert.deepEqual(await Reflect.apply(preprocessStyles, undefined, [source, callback]), {
    styles: ["sync", "", "", "", undefined],
    styleError: ["rejected", "thrown", "explicit error"],
  });
});

test("thenables and non-Error promise rejections follow official behavior", async () => {
  const source = "<style>a</style><style>b</style>";
  const callback = (content: string) => ({
    // oxlint-disable-next-line unicorn/no-thenable -- Verify PromiseLike callback results.
    then(resolve: (result: PreprocessorResult) => void, reject: (error: unknown) => void) {
      if (content === "a") resolve({ code: "thenable" });
      else reject(42);
    },
  });
  assert.deepEqual(await Reflect.apply(preprocessStyles, undefined, [source, callback]), {
    styles: ["thenable", ""],
    styleError: ["42"],
  });
});

test("without extractable styles even an async preprocessor returns synchronously", () => {
  const result = preprocessStyles("<style is:inline>p{}</style>", async () =>
    assert.fail("inline styles must not be preprocessed"),
  );
  assert.deepEqual<unknown>(result, { styles: [], styleError: [] });
});

test("Sass preprocessing and transform match official CSS for all scope strategies", async () => {
  const source =
    '<p class="panel"/><style lang="scss">$color:red;.panel {color:$color;&:hover {color:blue;}}</style><style is:inline>inline{}</style><style is:global>body{margin:0}</style>';
  const preprocessedStyles = await preprocessStyles(source, async (content, attrs) =>
    attrs.lang === "scss" ? { code: compileString(content).css } : null,
  );
  for (const scopedStyleStrategy of ["where", "class", "attribute"] as const) {
    const options = { preprocessedStyles, scopedStyleStrategy, sourcemap: "both" as const };
    const actual = transform(source, options);
    const expected = rustTransform(source, options);
    assert.deepEqual(actual.css.map(canonicalCss), expected.css.map(canonicalCss));
    assert.deepEqual(actual.styleError, expected.styleError);
    assert.deepEqual(JSON.parse(actual.map).sourcesContent, [source]);
  }
});

test("empty and self-closing style slots retain their preprocessing indices in transform", () => {
  const source =
    "<style/><style is:inline>skipped</style><style></style><style is:global>body{}</style>";
  let index = 0;
  const preprocessedStyles = preprocessStyles(source, () => ({ code: `p${index++}{color:red}` }));
  const options = { preprocessedStyles };
  assert.strictEqual(index, 3);
  assert.deepEqual(
    transform(source, options).css.map(canonicalCss),
    rustTransform(source, options).css.map(canonicalCss),
  );
  assert.deepEqual(transform("<style/>").css, []);
});

test("style callback results own their data and allow reentrant compiler calls", () => {
  const source = '<style lang="scss">outer</style>';
  const result = preprocessStyles(source, (content, attrs) => {
    assert.ok(parse("<p/>").ast);
    assert.ok(transform("<style>p{}</style>").css.length);
    const nested = preprocessStyles("<style>inner</style>", (value) => ({ code: value }));
    assert.deepEqual(nested.styles, ["inner"]);
    assert.strictEqual(attrs.lang, "scss");
    return { code: content };
  });
  preprocessStyles("<style>" + " ".repeat(100_000) + "</style>", () => null);
  assert.deepEqual(result, { styles: ["outer"], styleError: [] });
});

test("preprocessStyles is available from the built ESM entry", async () => {
  const module = await import("../dist/index.mjs");
  assert.strictEqual(typeof module.preprocessStyles, "function");
  assert.deepEqual(
    module.preprocessStyles("<style>p{}</style>", (code: string) => ({ code })),
    {
      styles: ["p{}"],
      styleError: [],
    },
  );
});

test("real Blume component extraction matches Rust", () => {
  const source = readFileSync(
    new URL("./fixtures/bench/blume/_FeatureBrowser.astro", import.meta.url),
    "utf8",
  );
  assert.deepEqual(
    preprocessStyles(source, (code) => ({ code })),
    rustPreprocess(source, (code) => ({ code })),
  );
});
