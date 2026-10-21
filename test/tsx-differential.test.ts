import { assert, test } from "vite-plus/test";
import { convertToTsx } from "../dist/index.mjs";
import { assertSyntax, assertVerbatim } from "./tsx-upstream/helpers.ts";
import fixtures from "./fixtures/tsx-differential-regressions.json" with { type: "json" };
import { convertToTsx as reference } from "@astrojs/astro2tsx";
import { assertTsxCompatibility, normalizeDiagnostics } from "./tsx-compat.ts";
import { categories, inputs } from "./fixtures/tsx-differential-inputs.ts";
import { isYukuPending } from "./yuku-pending.ts";

test("editor TypeScript grammar matches astro2tsx", () => {
  for (const javascript of [
    'import data from "test" assert {type:"json"};',
    'export {value} from "test" assert {type:"json"};',
    'import data from "test" with {type:"json"};',
    'import {assert as local} from "test";',
    "class C { method(@dec value:T){} }",
    "class C { constructor(@dec readonly value:T){} }",
    "try{}catch(error:T){}",
    "try{}catch(error:any){} try{}catch(error:unknown){}",
    "type T=Foo<?X,!Y,Z?,W!,?>;",
    "type T=[X?];",
    "break;const after=1;",
    "continue;const after=1;",
    "break missing;const after=1;",
    "const {...rest,}={};const after=1;",
    "interface Props<> {value:string}",
  ]) {
    for (const newline of ["\n", "\r\n"]) {
      const source = ["---", "// 🦊", javascript, "---", "<p/>"].join(newline);
      assertTsxCompatibility(source, convertToTsx(source), reference(source), true);
    }
  }
});

test("template diagnostic permissiveness matches astro2tsx", () => {
  for (const expression of [
    "!",
    "+",
    "-",
    "typeof",
    "void",
    "delete",
    "~",
    "a && b || c ?? d",
    "a ?? b || c",
  ]) {
    for (const source of [
      "{" + expression + "}",
      "<p>{" + expression + "}</p>",
      "<p value={" + expression + "}/>",
    ]) {
      assert.deepEqual(
        normalizeDiagnostics(convertToTsx(source)),
        normalizeDiagnostics(reference(source)),
        source,
      );
    }
  }
});

test("single unary frontmatter tokens match astro2tsx with open and closed fences", () => {
  for (const token of ["!", "+", "-", "typeof", "void", "delete", "~"]) {
    for (const newline of ["\n", "\r\n"]) {
      for (const tail of ["", newline + "---" + newline + "<p>🦊</p>"]) {
        const source = "---" + newline + token + tail;
        assertTsxCompatibility(source, convertToTsx(source), reference(source), true);
      }
    }
  }
});

test("nested attribute diagnostics retain their selected ranges after dialect transfer", () => {
  for (const source of [
    "{ok && <Component @x={,b} />}",
    "{ok && <Component @x={a,} />}",
    '{ok && <Component title="🦊" @x={a,} />}\r\n<p/>',
    "{ok && <Outer child={<Inner @x={,b} />}/>}",
  ]) {
    assert.deepEqual(
      normalizeDiagnostics(convertToTsx(source)),
      normalizeDiagnostics(reference(source)),
      source,
    );
  }
});

test("malformed JSX type arguments recover closing-tag tokens before regexp lexing", () => {
  for (const [source, positions] of [
    [
      "{ok && <div>a < Foo.Bar</div>}",
      [
        [24, 25],
        [25, 28],
        [29, 29],
      ],
    ],
    [
      "{ok && <div>a < b</div>}",
      [
        [18, 19],
        [19, 22],
        [23, 23],
      ],
    ],
    [
      '---\r\nconst face = "🦊";\r\n---\r\n{ok && <Card>a < b</Card>}',
      [
        [49, 50],
        [50, 54],
        [55, 55],
      ],
    ],
    [
      "{ok && <div>a < b< /div>}",
      [
        [0, 6],
        [25, 25],
      ],
    ],
  ] satisfies [string, number[][]][]) {
    const actual = convertToTsx(source);
    assert.deepEqual(normalizeDiagnostics(actual), normalizeDiagnostics(reference(source)));
    assert.deepEqual(
      actual.diagnostics.map(({ position }) => [position.start, position.end]),
      positions,
    );
  }
});

for (const category of categories)
  test("TSX generated compatibility inputs: " + category, () => {
    for (const input of inputs.filter((input) => input.category === category)) {
      assertTsxCompatibility(
        input.source,
        convertToTsx(input.source, input.options),
        reference(input.source, input.options),
        (category === "truncated" || category === "deleted") && input.source.startsWith("---"),
      );
    }
  });

for (const source of [
  '<p title={"a\n\r\t\0🦊"}/>',
  '<!custom "🦊"><p/>',
  '<!DOCTYPE html PUBLIC "a>b" "x"><html><body>🦊</body></html>',
  "---\ncontinue;const value=1;\n---\n<p>{value}</p>",
  "---\nbreak missing;const value=1;\n---\n<p>{value}</p>",
  "---\nclass C { method(){return 1; }\n---\n<p/>",
  "---\nconst {...rest,}={};const value=1;\n---\n<p>{value}</p>",
  "---\nconst value=100_;\n---\n<p>{value}</p>",
  "---\nconst value=0x_FF;\n---\n<p>{value}</p>",
  "---\nconst value=1e_2;\n---\n<p>{value}</p>",
  "---\nconst value=/x/uvv;\n---\n<p>{value}</p>",
  '<Card<Map<string,number> title="🦊"/>',
  "---\nfor(;;){continue;}\n---\n<p/>",
  "---\nouter:for(;;){break outer;}\n---\n<p/>",
  "---\nouter:for(;;){continue outer;}\n---\n<p/>",
])
  test.skipIf(isYukuPending(source, "tsx"))("TSX continuation diagnostics: " + source, () => {
    assertTsxCompatibility(source, convertToTsx(source), reference(source), true);
  });

for (const source of [
  "---\nconst fn=()=> <b>🦊</b>;\n---\n<p>{fn?.()}</p>",
  "---\nconst value={render(){return <b>🦊</b>}};\n---\n<p>{value.render()}</p>",
  "---\nclass Value{get child(){return <b>x</b>}}\n---\n<p>{new Value().child}</p>",
  "---\nfunction* f(){yield <b>a</b>;yield <i>b</i>}\n---\n<p>{[...f()]}</p>",
  '---\nconst values={x:<b>🦊</b>};const key="x";\n---\n<p>{values[key]}</p>',
  "<svg><![CDATA[a < b && c > d 🦊]]></svg>",
  '<?xml version="1.0"?><svg/>',
  "---\nfor(const value of [/a/uv]){}\n---\n<p/>",
  "---\nfunction f(){return /a/uv}\n---\n<p/>",
  '<p>{/a/uv.test("a")}</p>',
  "<p title={/a/uv.source}/>",
  "---\n/*🦊*/const a=/a/uv;/*x*/const b=/b/vu;const value=1;\n---\n<p>{value}</p>",
  "---\nconst value=1__0;\n---\n<p>{value}</p>",
  "---\nbreak;const value=1;\n---\n<p>{value}</p>",
  "---\nfunction f(...xs,y){}const value=1;\n---\n<p>{value}</p>",
  "---\nclass Value extends {}const value=1;\n---\n<p>{value}</p>",
])
  test.skipIf(isYukuPending(source, "tsx"))("TSX lexer and declaration recovery: " + source, () => {
    assertTsxCompatibility(source, convertToTsx(source), reference(source), true);
  });

for (const source of [
  "---\ninterface Props<T extends { [key: string]: any }, P extends string ? { [key: string]: any }: never> {}\n---\n<div/>\n",
  "---\nimport data from \"test\" assert { type: 'json' };\n---",
  "<div>{() => { if (value > 0.25) { return <br />;} else if (value > 0.5) { return <hr />;} else if (value > 0.75) { return <div />;} return <div>Yaaay</div>;}</div>",
])
  test("TSX fixture diagnostic recovery: " + source, () => {
    assertTsxCompatibility(source, convertToTsx(source), reference(source), true);
  });

for (const markup of [
  "<div @x={ a,b }></div>",
  "<div @x={ \t\n a,b }></div>",
  "<div @x={/*comment*/ a,b }></div>",
  "<div value={/*comment*/}></div>",
  "<div @x={/*comment*/}></div>",
  "<textarea><!--c--></textarea>",
  "<textarea><!--c--><!--d-->{x}</textarea>",
  "<textarea> <!--c--> b</textarea>",
  "<iframe><!--c--></iframe>",
  "<iframe> <!--c--> b</iframe>",
  "<math>{ok && <br>}</math>",
  "<math><mi>{x}</mi></math>",
  "<script><script>run()</script></script>",
  "<script>",
  "<div></div></div>",
  "<div>a < b</div>",
  "<div>< b/></div>",
  "<div><span>x</",
  "<iv><span>x</span></div>",
  "<Foo>a</FooBar></Foo>",
  "<foo></foobar></foo>",
  "<form.Field></form></form.Field>",
  "<C { foo } />",
  "<C { /*c*/foo } />",
  "<C {foo.bar} />",
  "<C {a,b} />",
  "<C { /*c*/ } />",
  "<C {/*a*/ id /*b*/} />",
  "<C { /*a*/ id /*b*/} />",
  "<C {/*c*/} />",
  "<C {//c\n} />",
  "<C {} />",
  "<C { } />",
]) {
  for (const source of [markup, "{ok && " + markup + "}"])
    test("TSX compatibility including diagnostic positions: " + source, () => {
      const expected = normalizeDiagnostics(reference(source));
      assert.deepEqual(normalizeDiagnostics(convertToTsx(source)), expected);
    });
}

for (const source of ["</div><span/>", "abc</div>xyz</p>", "<textarea><>{x}</b></textarea>"])
  test("TSX HTML closing-tag recovery: " + source, () => {
    assert.deepEqual(
      normalizeDiagnostics(convertToTsx(source)),
      normalizeDiagnostics(reference(source)),
    );
  });

for (const fixture of fixtures.results)
  test("TSX differential regression: " + fixture.name, () => {
    const result = convertToTsx(fixture.source, fixture.options);
    const { diagnostics, ...actual } = result;
    assert.deepEqual<unknown>(actual, fixture.expected);
    assert.strictEqual(diagnostics.length, 0);
    assertSyntax(result.code);
    assertVerbatim(fixture.source, result);
    for (const extracted of [...result.scripts, ...result.styles])
      assert.strictEqual(
        fixture.source.slice(extracted.position.start, extracted.position.end),
        extracted.content,
      );
  });
