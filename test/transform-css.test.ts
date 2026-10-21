import { assert, test } from "vite-plus/test";
import { transform as reference } from "@astrojs/compiler-rs";
import { transform, type TransformOptions } from "../dist/index.mjs";
import { canonicalCss } from "./css-compat.ts";
import { chromium } from "playwright-core";
import selectorRegressions from "./fixtures/css-selector-regressions.json" with { type: "json" };

const strategies = ["where", "class", "attribute"] as const;
function compile(
  css: string,
  scopedStyleStrategy: TransformOptions["scopedStyleStrategy"] = "where",
) {
  return transform("<p/><style/>", {
    filename: "/src/Styles.astro",
    scopedStyleStrategy,
    preprocessedStyles: { styles: [css], styleError: [] },
  });
}
function suffix(scope: string, strategy: (typeof strategies)[number]) {
  return strategy === "where"
    ? `:where(.astro-${scope})`
    : strategy === "class"
      ? `.astro-${scope}`
      : `[data-astro-cid-${scope}]`;
}

for (const fixture of selectorRegressions.cases) {
  test("CSS reference compatibility: " + fixture.name, () => {
    for (const strategy of strategies) {
      const css = fixture.selector + " {color:red}";
      const result = compile(css, strategy);
      const selector = fixture.expected
        .slice(0, fixture.expected.indexOf(" {"))
        .replaceAll(":where(.astro-SCOPE)", suffix(result.scope, strategy));
      assert.deepEqual(result.diagnostics, []);
      assert.deepEqual(result.css, [selector + " {color:red}"], strategy);
      const expected = reference("<p/><style/>", {
        filename: "/src/Styles.astro",
        scopedStyleStrategy: strategy,
        preprocessedStyles: { styles: [css], styleError: [] },
      });
      assert.strictEqual(result.scope, expected.scope);
      assert.deepEqual(result.css.map(canonicalCss), expected.css.map(canonicalCss));
    }
  });
}

test("CSS scoping preserves declaration bytes instead of normalizing values", () => {
  const body = String.raw`{
  background: url(/v0.5.png), url('white space.png');
  mask: url(data:image/svg+xml,%3Csvg%20viewBox='0;0{1}'%3E);
  color: blue; opacity: 0.5; animation-duration: 1000ms;
  font-family: version0.5;
  content: "🦊 /* comment */ :global(.literal) { ; }";
  --payload: { nested: { x: 0.5; }; list: [foo;bar] };
  \2d \2d escaped: { .literal { content: "raw" } };
  /* preserve this comment and its spacing */
}`.replaceAll("\n", "\r\n");
  for (const strategy of strategies) {
    const result = compile("p " + body, strategy);
    assert.deepEqual(result.diagnostics, []);
    assert.deepEqual(result.css, ["p" + suffix(result.scope, strategy) + " " + body]);
  }
});

test("namespaced universal selectors retain the required universal token", () => {
  const namespace = '@namespace svg url("http://www.w3.org/2000/svg");';
  for (const strategy of strategies) {
    const result = compile(namespace + "svg|*{fill:red}", strategy);
    assert.deepEqual(result.diagnostics, []);
    assert.deepEqual(result.css, [
      namespace + "svg|*" + suffix(result.scope, strategy) + "{fill:red}",
    ]);
  }
});

test("CSS selector parsing handles escapes, attributes and repeated globals", () => {
  const cases = [
    [":global(.a):global(.b)", ".a.b"],
    [":global(,ul,,ol,)", "ul, ol"],
    [":global(??,.a)", ".a"],
    [":global(.a/**/b,.x)", ".x"],
    [":is(??,:global(.a,.b))", "$S:is(.a, .b)"],
    [".local:global(button)", ".local$Sbutton"],
    [".local:global(button .child).tail", ".local$Sbutton .child.tail"],
    [":global(.a, .b):global(.c, .d)", ".a.c, .a.d, .b.c, .b.d"],
    [".local :global(ul, ol) .child", ".local$S ul .child$S, .local$S ol .child$S"],
    [":is(:global(.a, .b))", "$S:is(.a, .b)"],
    [":not(:global(.a):global(.b))", "$S:not(.a.b)"],
    [":host(:global(.a))", "$S:host(.a)"],
    ["::slotted(:global(.a))", "$S::slotted(.a)"],
    [":host(:global(.a):global(.b))", "$S:host(.a.b)"],
    [":nth-child(2n of :global(.a, .b))", "$S:nth-child(2n of :global(.a, .b))"],
    [String.raw`.\31 23:hover`, String.raw`.\31 23$S:hover`],
    [String.raw`.a\:b`, String.raw`.a\:b$S`],
    [String.raw`:glo\62 al(.a)`, ".a"],
    ['[data-value="/* :global(.x) ) */"]', '$S[data-value="/* :global(.x) ) */"]'],
    ["svg|a:hover", "svg|a$S:hover"],
    ["svg/**/|/**/a:hover", "svg/**/|/**/a$S:hover"],
    ["./**/panel", "./**/panel$S"],
    ["body.panel > p::before", "body.panel > p$S::before"],
    [":root.panel", ":root.panel"],
    [".panel:root", ".panel$S:root"],
  ];
  for (const strategy of strategies)
    for (const [input, expected] of cases) {
      const result = compile(input + " { color:blue; }", strategy);
      assert.deepEqual(result.diagnostics, []);
      assert.deepEqual(
        result.css,
        [expected.replaceAll("$S", suffix(result.scope, strategy)) + " { color:blue; }"],
        input,
      );
    }
});

test("nested rules scope parent references and relative selectors like the reference", () => {
  for (const css of [
    "nav { color:blue; a { color:red; span { opacity:0.5 } } }",
    ".panel { &:hover { color:blue } & .child { color:red } & > .child { color:white } }",
    ".panel { .child > .item { color:blue } :is(&) .child { color:red } }",
    ".panel { @media (min-width:10px) { color:blue; .child { color:red } & > .item { color:white } } }",
    ".panel { --payload:{x:y; z:{a:b}}; &:has(> .child) { color:blue } }",
    "@layer theme { @supports (display:grid) { @container (min-width:10px) { .panel { color:blue } } } }",
    "@scope (.root) to (.limit) { .child { color:blue } }",
    "@starting-style { .panel { opacity:0.5 } }",
  ])
    for (const strategy of strategies) {
      const actual = compile(css, strategy);
      const expected = reference("<p/><style/>", {
        filename: "/src/Styles.astro",
        scopedStyleStrategy: strategy,
        preprocessedStyles: { styles: [css], styleError: [] },
      });
      assert.strictEqual(actual.scope, expected.scope);
      assert.deepEqual(actual.css.map(canonicalCss), expected.css.map(canonicalCss), css);
    }
});

test("non-selector at-rule bodies and conditions remain unchanged", () => {
  const untouched = String.raw`/*! license */
@import url("/v0.5.css");
@font-face {font-family:'version0.5';src:url(/v0.5.woff2)}
@property --foo {syntax:"<color>";inherits:false;initial-value:blue}
@keyframes pulse { from {opacity:0.5} 50% {color:blue} to {opacity:1} }
@-webkit-keyframes spin {from{transform:rotate(0deg)}to{transform:rotate(360deg)}}
@page :first { margin:0.5cm; @top-left {content:"x"} }
@unknown future { value:{p:not(a){color:blue}} }
`;
  const result = compile(untouched + "@media (min-width: 10px) { p { color:blue } }");
  assert.deepEqual(result.css, [
    untouched +
      "@media (min-width: 10px) { p" +
      suffix(result.scope, "where") +
      " { color:blue } }",
  ]);
});

test("invalid rules and unfinished blocks do not disable scoping of other rules", () => {
  for (const strategy of strategies) {
    const result = compile(
      "p {color:blue} ?? {invalid:value} .a/**/b{color:red} .child {opacity:0.5",
      strategy,
    );
    const s = suffix(result.scope, strategy);
    assert.deepEqual(result.css, [
      `p${s} {color:blue} ?? {invalid:value} .a/**/b{color:red} .child${s} {opacity:0.5`,
    ]);
    const comments = compile(
      "<!-- p {color:blue} --> .child {opacity:0.5} /* unfinished",
      strategy,
    );
    assert.deepEqual(comments.css, [
      `<!-- p${s} {color:blue} --> .child${s} {opacity:0.5} /* unfinished`,
    ]);
  }
});

test("scoped selectors match the reference in a browser, including unscoped descendants", async () => {
  const browser = await chromium.launch({
    headless: true,
  });
  const mark = "outline:3px solid rgb(17,42,93)";
  const cases = [
    `p /* note */ {${mark}}`,
    `.a:global(.b):global(.c) {${mark}}`,
    `:global(.a,.b):global(.c,.d) {${mark}}`,
    `.panel :global(ul,ol) .child {${mark}}`,
    `:is(:global(.a,.b)) {${mark}}`,
    `:not(:global(.missing):global(.other)) {${mark}}`,
    `:has(> :global(.child,.item)) {${mark}}`,
    `:global([data-initial]:not([role='tab'])) unit-progress-icon, /* 1 */ :global([aria-selected='true']) unit-progress-icon /* 2 */ {${mark}}`,
    String.raw`.\31 23, .a\:b {${mark}}`,
    `p[data-value="/* :global(.x) ) */"] {${mark}}`,
    `body > .panel {${mark}}`,
    `:root .panel {${mark}}`,
    `.panel { .child {${mark}} }`,
    `.panel { & .child {${mark}} }`,
    `.panel { & > .child {${mark}} }`,
    `.panel { :is(&) .child {${mark}} }`,
    `.panel { .child > .item {${mark}} }`,
    `.panel { @media (min-width:0px) { .child {${mark}} } }`,
    `@layer example { @supports (display:grid) { .panel .child {${mark}} } }`,
    `@container (min-width:0px) { .child {${mark}} }`,
    `@scope (.root) to (.limit) { .child {${mark}} }`,
  ];
  const html = `<div id="outside" class="panel a b c d"><p id="outside-child" class="child">outside</p></div>
    <main id="root" class="root panel a b c d" data-owned style="container-type:inline-size">
      <p id="owned" class="child a b c d" data-owned data-value="/* :global(.x) ) */">owned</p>
      <div id="unscoped" class="child">unscoped<span id="item" class="item" data-owned>item</span></div>
      <ul data-owned><li id="list-child" class="child" data-owned>list</li></ul>
      <p id="escaped" class="123 a:b" data-owned>escaped</p>
      <div class="limit"><p id="limited" class="child" data-owned>limited</p></div>
      <a data-initial><unit-progress-icon id="icon" data-owned>icon</unit-progress-icon></a>
    </main>`;
  try {
    const page = await browser.newPage();
    for (const strategy of strategies)
      for (const { css, mustMatch } of [
        ...cases.map((css) => ({ css, mustMatch: true })),
        ...selectorRegressions.cases.map((fixture) => ({
          css: fixture.selector + ` {${mark}}`,
          mustMatch: false,
        })),
      ]) {
        const actual = compile(css, strategy);
        const expected = reference("<p/><style/>", {
          filename: "/src/Styles.astro",
          scopedStyleStrategy: strategy,
          preprocessedStyles: { styles: [css], styleError: [] },
        });
        const states = [];
        for (const result of [expected, actual]) {
          await page.setContent(
            '<html id="document-root" class="foo"><body id="document-body" class="bar">' +
              html +
              "</body></html>",
          );
          await page.locator("[data-owned]").evaluateAll(
            (elements, { scope, strategy }) => {
              for (const element of elements) {
                if (strategy === "attribute") element.setAttribute("data-astro-cid-" + scope, "");
                else element.classList.add("astro-" + scope);
              }
            },
            { scope: result.scope, strategy },
          );
          await page.addStyleTag({ content: result.css.join("\n") });
          states.push(
            await page.locator("[id]").evaluateAll((elements) =>
              elements.map((element) => ({
                id: element.id,
                outline: getComputedStyle(element).outlineStyle,
                width: getComputedStyle(element).outlineWidth,
                color: getComputedStyle(element).outlineColor,
              })),
            ),
          );
        }
        assert.deepEqual(states[1], states[0], strategy + ": " + css);
        assert.strictEqual(
          states[0].some((item) => item.outline === "solid"),
          mustMatch,
          "Reference selector match status: " + css,
        );
      }
  } finally {
    await browser.close();
  }
}, 60000);
