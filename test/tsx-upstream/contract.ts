import { upstream, assert, convert, contains, absent } from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("tests/contract.rs", name, body);
test("never_fails_on_truncated_input", () => {
  for (const source of [
    '<div>{"<br/>"}</div>',
    "<div>{'<b>y</b>'}</div>",
    "<div>{`<b>y</b>`}</div>",
    "<div>{foo<Bar>(x)}</div>",
    "<div>{a.b<C<D>>(y)}</div>",
    "<div>{c && <span>a</span> <span>b</span>}</div>",
    "<div>{l.map(i => <span>{i}</span>)}</div>",
    "{list.map(() => <Component><!--Hi--></Component>)}",
    "<div>{x && <span><!--hi--></span>}</div>",
    "<div>{...rest}</div>",
    "<div>{ {a:1} }</div>",
    "<div>{/* c */}</div>",
    "hello\n---\nconst a = 1;\n---\n<p>x</p>",
    '<div a= b="c"></div>',
    "<Comp a='it\\'s' />",
    "<div class=`></div>",
    '---\nconst x = 1;\n---\n<div class="a">{x}<style>.a{color:red}</style></div>',
  ]) {
    for (let end = 0; end <= source.length; end++) {
      const result = convert(source.slice(0, end), { filename: "index.astro" });
      assert.ok(result.code.length);
      assert.ok(result.code.startsWith("/* @jsxImportSource astro */"));
    }
  }
});
for (const [name, source, tag, excluded] of [
  [
    "script_text_is_excluded_but_the_tag_remains",
    "<script>const a = 1;</script>",
    "<script>",
    "const a = 1;",
  ],
  [
    "json_script_text_is_excluded_but_the_tag_remains",
    '<script type="application/json">{"a":1}</script>',
    '<script type="application/json">',
    '"a":1',
  ],
  [
    "unknown_script_text_is_excluded_but_the_tag_remains",
    '<script type="text/nonsense">wat wat</script>',
    '<script type="text/nonsense">',
    "wat wat",
  ],
  [
    "style_text_is_excluded_but_the_tag_remains",
    "<style>.a { color: red; }</style>",
    "<style>",
    "color: red",
  ],
])
  test(name, () => {
    const result = convert(source);
    contains(result.code, tag);
    if (source.startsWith("<script>")) contains(result.code, "</script>");
    if (source.startsWith("<style>")) contains(result.code, "</style>");
    absent(result.code, excluded);
  });
test("raw_text_is_still_emitted", () =>
  contains(convert("<div is:raw><b>not markup</b></div>").code, "{`<b>not markup</b>`}"));
test("script_and_style_win_over_is_raw", () => {
  absent(convert("<script is:raw>const a = 1;</script>").code, "const a = 1;");
  absent(convert("<style is:raw>.a { color: red; }</style>").code, "color: red");
});
test("excluded_bodies_are_still_reported_as_extracted_tags", () => {
  const result = convert("<script>const a = 1;</script><style>.a{color:red}</style>");
  assert.equal(result.scripts.length, 1);
  assert.equal(result.scripts[0].content, "const a = 1;");
  assert.equal(result.styles.length, 1);
  assert.equal(result.styles[0].content, ".a{color:red}");
});
