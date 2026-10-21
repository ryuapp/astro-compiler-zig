import { assert, expect, test } from "vite-plus/test";
import path from "node:path";
import { pathToFileURL } from "node:url";
import { createRequire } from "node:module";
import { transform } from "../dist/index.mjs";
import { transform as reference } from "@astrojs/compiler-rs";
import { canonicalCss } from "./css-compat.ts";
const require = createRequire(import.meta.url);
const directory = path.dirname(require.resolve("astro/package.json"));
const { experimental_AstroContainer: AstroContainer } = await import(
  pathToFileURL(path.join(directory, "dist/container/index.js")).href
);
const internalURL = pathToFileURL(path.join(directory, "dist/runtime/server/index.js")).href;
const container = await AstroContainer.create();
function compile(source: string, options = {}) {
  const result = transform(source, {
    internalURL,
    resolvePath: (s) => s,
    inlineComponentAssets: true,
    ...options,
  });
  assert.deepEqual(result.diagnostics, [] as any[]);
  return "data:text/javascript;base64," + Buffer.from(result.code).toString("base64");
}
async function render(source: string, options = {}) {
  const module = await import(compile(source));
  return container.renderToString(module.default, options);
}
function check(name: string, source: string, expected: string, options = {}) {
  test(name, async () => {
    assert.strictEqual(await render(source, options), expected);
  });
}
check(
  "TypeScript and escaped expressions",
  '---\nconst name: string="<World>";\n---\n<h1>Hello {name}</h1>',
  "<h1>Hello &lt;World&gt;</h1>",
);
check("Astro props", "---\nconst {name}=Astro.props;\n---\n<p>{name}</p>", "<p>reader</p>", {
  props: { name: "reader" },
});
check(
  "closed inline scripts preserve following HTML whitespace",
  '<div>\n<script is:inline>console.log("test");</script>\n  <p>after</p>\n</div>',
  '<div>\n<script>console.log("test");</script>\n  <p>after</p>\n</div>',
);
check(
  "closed module scripts preserve whitespace before head closes",
  '<html>\n<head>\n<script type="module" src="/test.js"></script>\n  </head>\n<body>text</body></html>',
  '<html>\n<head>\n<script type="module" src="/test.js"></script>\n  </head>\n<body>text</body></html>',
);
check(
  "self-closing scripts preserve following HTML whitespace",
  '<div><script type="module" src="/test.js"/>\n  <p>after</p></div>',
  '<div><script type="module" src="/test.js"></script>\n  <p>after</p></div>',
);
check(
  "closed scripts preserve JS-looking text as HTML",
  "<div><script is:inline>run()</script>/*hi*/<p/></div>",
  "<div><script>run()</script>/*hi*/<p></p></div>",
);
check(
  "self-closing scripts preserve conditional expression delimiters",
  '---\r\nconst payload = JSON.stringify({name:"🦊"});\r\n---\r\n<head>{true && (<script is:inline set:html={payload} type="application/ld+json" />)}</head>',
  '<head><script type="application/ld+json">{"name":"🦊"}</script></head>',
);
check(
  "self-closing scripts preserve ternary alternates",
  '{true ? <script is:inline set:html={"raw"}/> : <p>unused</p>}',
  "<script>raw</script>",
);
check(
  "closed scripts inside markup expressions preserve following text",
  "{true && (<div><script is:inline>x()</script> text<p/></div>)}",
  "<div><script>x()</script> text<p></p></div>",
);
check(
  "trusted HTML and escaped text",
  '<div set:html={"<b>raw</b>"}/><p set:text={"<b>text</b>"}/>',
  "<div><b>raw</b></div><p>&lt;b&gt;text&lt;/b&gt;</p>",
);
check(
  "attribute escaping and class lists",
  '---\nconst title = \'"><x>\';\n---\n<p title={title} class:list={["a", {b:true,c:false}]} />',
  '<p title="&quot;><x>" class="a b"></p>',
);
test("scoped class lists and spreads render the same attributes as compiler-rs", async () => {
  for (const attributes of ["class:list={classes} {...attrs}", "{...attrs} class:list={classes}"]) {
    for (const scopedStyleStrategy of ["attribute", "class", "where"] as const) {
      const source = `---\r\nconst classes = ['local', {active:true}];\r\nconst attrs = {id:'target', title:'🦊', class:'from-spread'};\r\n---\r\n<p ${attributes}/><style>p{color:red}</style>`;
      const options = {
        internalURL,
        resolvePath: (specifier: string) => specifier,
        scopedStyleStrategy,
        inlineComponentAssets: true,
        sourcemap: "both" as const,
      };
      const html = [];
      for (const compiler of [reference, transform]) {
        const result = compiler(source, options);
        assert.deepEqual(result.diagnostics, []);
        const module = await import(
          "data:text/javascript;base64," + Buffer.from(result.code).toString("base64")
        );
        const rendered = await container.renderToString(module.default);
        html.push(
          rendered.replace(
            /<style>([\s\S]*?)<\/style>/gu,
            (_: string, css: string) => "<style>" + canonicalCss(css) + "</style>",
          ),
        );
      }
      assert.strictEqual(html[1], html[0], scopedStyleStrategy + ": " + attributes);
    }
  }
});
const card = compile(
  '<article><slot name="title"/><slot name="item-0"/><slot name="item-1"/><slot/></article>',
);
const start = "---\nimport Card from " + JSON.stringify(card) + ";\n";
for (const [name, content, compacted] of [
  ["direct text", "\n  text\n", "\n  text\n"],
  ["HTML child", "<p>\n  Type to search…\n</p>", "<p>Type to search…</p>"],
  ["nested HTML", "<div><p>\r\n  🦊 text\r\n</p></div>", "<div><p>🦊 text</p></div>"],
  ["raw text", "<pre>\n  text\n</pre>", "<pre>\n  text\n</pre>"],
  ["fragment", "<Fragment>\n  text\n</Fragment>", "\n  text\n"],
] as const) {
  test("JSX compaction resets inside slotted HTML: " + name, async () => {
    const source = start + "---\n<Card>" + content + "</Card>";
    for (const compact of [false, "jsx"] as const) {
      const options = {
        compact,
        internalURL,
        resolvePath: (specifier: string) => specifier,
        sourcemap: "both" as const,
      };
      const expected = reference(source, options);
      const actual = transform(source, options);
      assert.deepEqual(expected.diagnostics, []);
      assert.deepEqual(actual.diagnostics, []);
      const html = [];
      for (const result of [expected, actual]) {
        const module = await import(
          "data:text/javascript;base64," + Buffer.from(result.code).toString("base64")
        );
        html.push(await container.renderToString(module.default));
      }
      assert.strictEqual(
        html[0],
        "<article>" +
          (compact === "jsx"
            ? compacted
            : content.replaceAll(/<\/?Fragment>/gu, "").replaceAll("\r\n", "\n")) +
          "</article>",
      );
      assert.strictEqual(html[1], html[0]);
    }
  });
}
check(
  "conditional named slots",
  start +
    'const yes=true;\n---\n<Card>{yes ? <h1 slot="title">Title</h1> : <h1 slot="other">Other</h1>}</Card>',
  "<article><h1>Title</h1></article>",
);
check(
  "mapped dynamic slots",
  start +
    'const items=["A","B"];\n---\n<Card>{items.map((item,i)=><b slot={`item-${i}`}>{item}</b>)}</Card>',
  "<article><b>A</b><b>B</b></article>",
);
check(
  "async mapped dynamic slots",
  start +
    'const items=["A","B"];\n---\n<Card>{items.map(async (item,i)=><b slot={`item-${i}`}>{await Promise.resolve(item)}</b>)}</Card>',
  "<article><b>A</b><b>B</b></article>",
);
check(
  "Fragment keeps browser slot attributes",
  start + 'const yes=true;\n---\n<Card>{yes && <><h1 slot="title">Title</h1><p>Body</p></>}</Card>',
  '<article><h1 slot="title">Title</h1><p>Body</p></article>',
);
check(
  "enum values and reverse mappings",
  '---\nenum X {A="a",B=A+"b",C=1<<2,D=C+1}\n---\n<p>{X.A}:{X.B}:{X.C}:{X.D}:{X[4]}</p>',
  "<p>a:ab:4:5:C</p>",
);
check(
  "computed enum values and lexical shadowing",
  "---\nconst f=()=>5; enum X {A=f(),B=A+1,C=((A:number)=>A)(20)}\n---\n<p>{X.A}:{X.B}:{X.C}</p>",
  "<p>5:6:20</p>",
);
check("enum merging", "---\nenum X {A=1} enum X {B=2}\n---\n<p>{X.A}:{X.B}</p>", "<p>1:2</p>");
check(
  "namespace live values",
  "---\nnamespace X {export const n=2;export let count=0;export function inc(){count++}} X.inc(); X.count=4;\n---\n<p>{X.n}:{X.count}</p>",
  "<p>2:4</p>",
);
check(
  "namespace enum",
  "---\nnamespace X {export enum Y {A,B}}\n---\n<p>{X.Y.A}:{X.Y.B}</p>",
  "<p>0:1</p>",
);
check(
  "namespace merging",
  "---\nnamespace X {export let n=2} namespace X {export function inc(){n++}} X.inc();\n---\n<p>{X.n}</p>",
  "<p>3</p>",
);
check(
  "qualified namespace",
  "---\nnamespace X.Y.Z {export const n=4}\n---\n<p>{X.Y.Z.n}</p>",
  "<p>4</p>",
);
check(
  "namespace destructuring exports",
  "---\nnamespace X {export const {a,b:renamed}={a:1,b:2};export const [c]=[3]}\n---\n<p>{X.a}:{X.renamed}:{X.c}</p>",
  "<p>1:2:3</p>",
);
check(
  "enum arithmetic follows JavaScript",
  "---\nenum X {A=-5,B=A%3,C=1/0,D=0/0}\n---\n<p>{X.B}:{X.C}:{String(X.D)}</p>",
  "<p>-2:Infinity:NaN</p>",
);
check(
  "parameter properties",
  "---\nclass X {constructor(public value:number=3){}} const x=new X();\n---\n<p>{x.value}</p>",
  "<p>3</p>",
);
check("import equals", "---\nconst X={Y:5}; import Y=X.Y;\n---\n<p>{Y}</p>", "<p>5</p>");
check(
  "native elements preserve client and server attributes",
  '<p client:only="react" server:defer="later">🦊</p>',
  '<p client:only="react" server:defer="later">🦊</p>',
);
check(
  "slot names use default-hint string coercion",
  '<slot name={{[Symbol.toPrimitive](hint){return hint==="default"?"chosen":"wrong"}}}><b>fallback</b></slot>',
  "<b>provided</b>",
  { slots: { chosen: "<b>provided</b>" } },
);
check(
  "JSX satisfies keeps rendered children",
  "<p>{(<b>x</b> satisfies unknown)}</p>",
  "<p><b>x</b></p>",
);
check(
  "JSX const tuple keeps rendered children",
  "<p>{([<b>x</b>,<i>y</i>] as const)}</p>",
  "<p><b>x</b><i>y</i></p>",
);

test("abstract computed fields are erased without evaluating their keys", async () => {
  const source = `---\r\nlet calls=0;\r\nconst key=()=>{calls++;return "computed"};\r\nabstract class Base {abstract [key()]:number; abstract named:number;}\r\nconst value=new (class extends Base {})();\r\n---\r\n<p>{Object.keys(value).join(",")}:{calls}</p>`;
  const results = [];
  for (const compiler of [reference, transform]) {
    const result = compiler(source, {
      internalURL,
      resolvePath: (specifier) => specifier,
      sourcemap: "both",
    });
    assert.deepEqual(result.diagnostics, []);
    const module = await import(
      "data:text/javascript;base64," + Buffer.from(result.code).toString("base64")
    );
    results.push(await container.renderToString(module.default));
  }
  assert.deepEqual(results, ["<p>:0</p>", "<p>:0</p>"]);
});

test("parameter properties preserve constructor directive prologues", async () => {
  const source =
    '---\nclass Value {constructor(public value=3){"use strict";}}\n---\n<p>{new Value().value}</p>';
  for (const compiler of [reference, transform]) {
    const result = compiler(source, { internalURL, resolvePath: (specifier) => specifier });
    assert.deepEqual(result.diagnostics, []);
    // Assignment insertion must not turn a directive into an ordinary string
    // statement and accidentally make this invalid JavaScript executable.
    await expect(
      import("data:text/javascript;base64," + Buffer.from(result.code).toString("base64")),
    ).rejects.toThrow(SyntaxError);
  }
});
