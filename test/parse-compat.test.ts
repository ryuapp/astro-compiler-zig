import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { assert, test } from "vite-plus/test";
import { parse as reference } from "@astrojs/compiler-rs";
import { parse } from "../dist/index.mjs";
import { fixtures } from "./fixtures/compiler-rs-syntax.json" with { type: "json" };
import biome from "./fixtures/biome/origin.json" with { type: "json" };
import scriptBoundaries from "./fixtures/script-boundary-reference.json" with { type: "json" };
import { isYukuPending } from "./yuku-pending.ts";

function files(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const file = join(directory, entry.name);
    return entry.isDirectory() ? files(file) : file.endsWith(".astro") ? [file] : [];
  });
}

const inputs = ["biome", "tsx-upstream", "transform-upstream", "bench"].flatMap((directory) =>
  files(join(import.meta.dirname, "fixtures", directory)).map((file) => ({
    name: file.slice(import.meta.dirname.length + 1),
    source: readFileSync(file, "utf8"),
  })),
);
inputs.push(...fixtures);
for (const fixture of biome.fixtures.filter((fixture) => fixture.kind === "expression")) {
  const source =
    biome.expressionWrapper.prefix +
    readFileSync(join(import.meta.dirname, "fixtures/biome", fixture.file), "utf8") +
    biome.expressionWrapper.suffix;
  if ("parseThrows" in fixture) {
    test("quoted attribute name matches the reference's JSON serialization failure", () => {
      assert.throws(() => reference(source), SyntaxError);
      assert.throws(() => parse(source), SyntaxError);
    });
  } else inputs.push({ name: fixture.file, source });
}
inputs.push(
  ...[
    "<style>",
    "<style>a{}",
    "<div is:raw>",
    "<input",
    "<input a={x}",
    "<input a={x + }/>",
    "<input {...x +",
  ].map((source) => ({ name: "unfinished input " + source, source })),
);
inputs.push(
  ...[
    '<svg:svg xml:lang="ja"><svg:path d="M0 0"/></svg:svg>',
    "<svg:path></svg:circle>",
    '<!custom "🦊"><p/>',
    '<!DOCTYPE html PUBLIC "a>b" "x"><html><body>🦊</body></html>',
    "---\nfunction f(...xs,){}const value=1;\n---\n<p>{value}</p>",
    "---\nconst [...xs,last]=[1,2];const value=1;\n---\n<p>{value}</p>",
    "---\nconst value=100_;\n---\n<p>{value}</p>",
    "---\nclass C extends /*x*/ {}const value=1;\n---\n<p>{value}</p>",
    "---\nconst value=100_ /*🦊*/;\n---\n<p/>",
    "---\nconst a=10_;function f(...xs,){}const b=/x/uv;\n---\n<p/>",
    "---\nconst a=10_;const b=/x/g;\n---\n<p/>",
  ].map((source, index) => ({ name: "Token recovery and declarations " + index, source })),
);
inputs.push(
  ...[
    '<p>{/a/uv.test("a")}</p>',
    "<p title={/a/uv.source}/>",
    "<p>{[/a/uv,/b/vu]}</p>",
    "<p>🦊{/*before*/ /a/uv.source /*after*/}</p>",
    "<p title={true ? /a/uv : /b/vu}>🦊</p>",
    "<p>{(()=>{return /a/uv})()}</p>",
    "{[<b/>,/a/uv]}",
    "<svg><![CDATA[a < b && c > d 🦊]]></svg>",
    "<svg><![CDATA[🦊</svg>",
  ].map((source, index) => ({ name: "Markup recovery boundary " + index, source })),
);
inputs.push(
  ...[
    '---\nconst text="🦊";const value=/[abc/;\n---\n<p/>',
    '---\nconst first="🦊";const value:{x:;\n---\n<p/>',
    "---\nfunction f<T( ){return 1}\n---\n<p/>",
    "---\nfunction f(){return /---/.source;} const value=f();\n---\n<p>{value}</p>",
    "---\nconst value=/a/uv;\n---\n<p/>",
    "---\r\n/*🦊*/const first=/a/uv;const second=/b/vu;\r\n---\r\n<p/>",
    '} const ignored="🦊";<p/>',
  ].map((source, index) => ({ name: "Program recovery boundary " + index, source })),
);

inputs.push(
  ...["\n", "\r\n", "\r"].flatMap((newline) =>
    ["/[abc/;", "/[abc\\", "/abc\\"].map((expression) => ({
      name: "Unterminated frontmatter regex before fence " + JSON.stringify([newline, expression]),
      source: ["---", "const value=" + expression, "---", "<p>🦊</p>"].join(newline),
    })),
  ),
);

inputs.push(
  ...["\n", "\r\n", "\r"].map((newline) => ({
    name: "Unicode and comments " + JSON.stringify(newline),
    source: [
      "---",
      "// 🦊",
      "const 日本語 = 'é';",
      "---",
      "<p title={日本語}>🦊{/* é */}</p>",
    ].join(newline),
  })),
);
inputs.push(
  ...[
    "---\n/* frontmatter only */\n---\n<script>/* script only */</script><script>\n// before code\nconst x = 1;</script>",
    "---\r\n// before code\r\nconst title = 'ok';\r\n---\r\n<script> // empty\r\n</script><script>\r\n/* before code */\r\nconst x = 1;</script>",
    "<p>🦊</p><script>/* é */\nconst 日本語 = '🦊';</script><script>\nconst x = 2;</script>",
  ].map((source, index) => ({ name: "Program starts across token boundaries " + index, source })),
);
inputs.push(
  ...[
    '<Card a={true ? <Inner x="🦊" y={1}/> : null} b="after" c={{ child: <Leaf/> }}/>',
    '<Card a={value + /* keep */} b="after"/>{/* after */}',
    '<><Card first={<Inner a={{ child: <Leaf/> }} b="last"/>} second="after"/>{/* end */}</>',
  ].map((source, index) => ({ name: "Nested markup and recovery comments " + index, source })),
);
inputs.push(
  ...[
    '{true && (<script is:inline set:html={"🦊"} />)}',
    '<head>{true && (<script is:inline set:html={"🦊"} />)}</head>',
    "{true ? <script is:inline/> : <p/>}",
    "{[<script is:inline/>, <p/>]}",
    "<div>{true && (<script is:inline>x()</script>)}</div>",
    "{true && (<div><script is:inline>x()</script> text<p/></div>)}",
    "<Card script={true ? <script is:inline/> : null}/>",
  ].map((source, index) => ({ name: "Scripts return to JavaScript expressions " + index, source })),
);

for (const identifier of ["title", "__astro_native_0", "\\u005f_astro_native_0"]) {
  const elements = Array.from(
    { length: 24 },
    (_, index) => `<Card index={${index}} title={${identifier}}><Leaf/></Card>`,
  ).join(", ");
  inputs.push({
    name: "Markup markers retain distinct pooled names with identifier " + identifier,
    source: `---\r\nconst ${identifier} = '🦀';\r\nconst elements = [${elements}];\r\n---\r\n{elements}`,
  });
}

for (const prefix of ["", "a".repeat(15), "a".repeat(16), "a".repeat(17), "a".repeat(65_536)]) {
  for (const source of [
    prefix + "🦀",
    prefix + '<p title="日本語">é{1 + 2}{/* 🦀 */ 3}</p>',
    `---\r\n// ${prefix}\r\nconst before = 1;\r\nconst 日本語 = '🦀';\r\n---\r\n<Card title={日本語}>{before}</Card>`,
    prefix + '<p title="🦀">{value + /* 日本語 */}</p>',
  ]) {
    inputs.push({
      name: `Non-ASCII suffix after ${prefix.length} ASCII characters: ${source.slice(-60)}`,
      source,
    });
  }
}

for (const length of [0, 15, 16, 17, 1024]) {
  for (const value of [
    "\u00e9",
    "\u65e5\u672c\u8a9e",
    "\ud83e\udd80",
    "e\u0301",
    "\ud800",
    "\udc00",
    "\ud800\ud800",
  ]) {
    const text = "a".repeat(length) + value;
    inputs.push({
      name: `Unicode positions after ${length} ASCII characters: ${JSON.stringify(value)}`,
      source: `---\r\nconst text = ${JSON.stringify(text)};\r\n---\r\n<p title="${text}">${text}{/* ${value} */ text}</p>`,
    });
  }
}

inputs.push(
  {
    name: "shared range dialect empty document",
    source: "",
  },
  {
    name: "shared range dialect simple element",
    source: "<p>Hello</p>",
  },
  {
    name: "shared range dialect root sibling elements",
    source: "<p>a</p><p>b</p>",
  },
  {
    name: "shared range dialect plain root text",
    source: "Hello <p>world</p>",
  },
  {
    name: "shared range dialect root emoji",
    source: "🦊<p>world</p>",
  },
  {
    name: "shared range dialect root backslash",
    source: "\\<p>world</p>",
  },
  {
    name: "shared range dialect root unmatched quote",
    source: "'<p>world</p>",
  },
  {
    name: "shared range dialect root HTML comment",
    source: "<!-- comment --><p/>",
  },
  {
    name: "shared range dialect root doctype",
    source: "<!doctype html><html><body>Hello</body></html>",
  },
  {
    name: "shared range dialect void element",
    source: "<p>a<br>b<img src=logo.svg></p>",
  },
  {
    name: "shared range dialect unquoted attribute",
    source: "<div class=box id=main />",
  },
  {
    name: "shared range dialect shorthand and spread",
    source: "<Card {title} {...props}/>",
  },
  {
    name: "shared range dialect raw script",
    source: "<script>const x={a:1};if(x.a < 2) console.log(x)</script>",
  },
  {
    name: "shared range dialect raw CSS",
    source: "<style>p:hover{color:red}</style>",
  },
  {
    name: "shared range dialect is raw",
    source: "<div is:raw>{not JavaScript} <wow></div>",
  },
  {
    name: "shared range dialect child expression",
    source: "<p>{value + 1}</p>",
  },
  {
    name: "shared range dialect attribute expression",
    source: "<Card value={f(1)}/>",
  },
  {
    name: "shared range dialect nested markup expression",
    source: "<div>{ok && <b>{value}</b>}</div>",
  },
  {
    name: "shared range dialect adjacent markup expression",
    source: "<div>{ok && <b/><i/>}</div>",
  },
  {
    name: "shared range dialect frontmatter const",
    source: "---\nconst title='hello';\n---\n<p>{title}</p>",
  },
  {
    name: "shared range dialect frontmatter import",
    source: "---\nimport Card from './Card.astro';\n---\n<Card/>",
  },
  {
    name: "shared range dialect frontmatter export",
    source: "---\nexport const prerender=true;\n---\n<p/>",
  },
  {
    name: "shared range dialect frontmatter exported Props",
    source: "---\nexport interface Props {title:string}\n---\n<p/>",
  },
  {
    name: "shared range dialect frontmatter return",
    source: "---\nreturn;\n---\n<p/>",
  },
  {
    name: "shared range dialect frontmatter await",
    source: "---\nconst title=await Promise.resolve('a');\n---\n<p>{title}</p>",
  },
  {
    name: "shared range dialect frontmatter regex fence",
    source: "---\nconst title=/---/.source;\n---\n<p>{title}</p>",
  },
  {
    name: "shared range dialect frontmatter no semicolon",
    source: "---\nconst title='hello'\n---\n<p>{title}</p>",
  },
  {
    name: "shared range dialect frontmatter comments",
    source: "---\n/* 🦊 */ const title='hello';\n---\n<p>{title}</p>",
  },
  {
    name: "shared range dialect CRLF and Unicode",
    source: "---\r\nconst 名前='🦊';\r\n---\r\n<p title={名前}>日本語</p>",
  },
  {
    name: "shared range dialect generic arrow and markup",
    source:
      "---\nconst identity = <T,>(value:T)=>value;\n---\n{identity(1)}{<p>(hello): world</p>}",
  },
);

inputs.push({
  name: "shared range dialect generator context",
  source: "---\nfunction* values() { return <p>{yield 1}</p>; }\n---\n{values()}",
});

inputs.push({
  name: "shared range dialect async context",
  source:
    "---\nasync function view() { return <p>{await Promise.resolve('🦊')}</p>; }\n---\n{await view()}",
});

// These inputs contain invalid JS whose partial tree depends on parser recovery.
// Keep malformed Astro markup under the full AST comparison elsewhere in this suite.
const javascriptRecovery = new Set([
  "logical expression",
  "root missing binary RHS",
  "root missing binary stops body",
  "root missing unary operand",
  "root missing multiplicative RHS",
  "root missing conditional alternate",
  "root nested missing RHS",
  "crates/biome_js_parser/tests/js_test_suite/ok/astro_is_raw_end_tag_name_boundary.astro_expr.tsx",
  "unfinished input <input a={x + }/>",
  "unfinished input <input {...x +",
  "Token recovery and declarations 4",
  "Token recovery and declarations 5",
  "Token recovery and declarations 7",
  "Program recovery boundary 0",
  "Program recovery boundary 1",
  "Program recovery boundary 2",
  "Program recovery boundary 3",
]);

for (const { name, source } of inputs) {
  test.skipIf(isYukuPending(source, "ast"))("compiler-rs public AST: " + name, () => {
    const result = parse(source);
    const referenceResult = reference(source);
    const expected = referenceResult.ast;
    const actualError = result.diagnostics.some((diagnostic) => diagnostic.severity === "error");
    const expectedError = referenceResult.diagnostics.some(
      (diagnostic) => diagnostic.severity === "error",
    );
    assert.strictEqual(actualError, expectedError, "parse error status: " + source);
    const correction = scriptBoundaries.parse.find((fixture) => fixture.source === source);
    if (correction) {
      assert.deepEqual(expected, correction.publishedAst);
      assert.deepEqual<unknown>(result.ast, correction.expectedAst);
    } else if (!expectedError || !javascriptRecovery.has(name)) {
      // Invalid JS may retain different partial trees after both parsers report an error.
      assert.deepEqual(result.ast, expected);
    }
    for (const diagnostic of result.diagnostics) {
      assert.strictEqual(typeof diagnostic.text, "string");
      assert.strictEqual(typeof diagnostic.hint, "string");
      for (const label of diagnostic.labels) {
        assert.ok(
          label.start >= 0 && label.end >= label.start && label.end <= Buffer.byteLength(source),
        );
        assert.ok(label.line >= 1 && label.column >= 0);
      }
    }
  });
}

// inspect document text directly because the reference lexer rejects some HTML text
test("script boundaries keep following HTML text out of the JS lexer", () => {
  for (const tail of ["hello", "🦊", "\\", '"unfinished', "\r\n🦊"]) {
    for (const script of ["<script>run()</script>", "<script/>"]) {
      const source = "<div>" + script + tail + "</div>";
      const result = parse(source);
      assert.deepEqual(result.diagnostics, []);
      const element = result.ast.body[0];
      assert.strictEqual(element.type, "JSXElement");
      assert.strictEqual(element.children.at(-1).raw, tail);
    }
  }
});
