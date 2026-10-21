import { upstream, assert, clean, convert, contains, absent } from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("src/render/extracted.rs", name, body);
test("metadata_is_independent_of_rendering_context", () => {
  for (const [attribute, expected] of [
    ["", "css"],
    ["lang={lang}", "unknown"],
    ["lang=`${lang}`", "unknown"],
    ["lang", ""],
    ['lang=""', ""],
    ['lang=" SCSS "', "scss"],
    ["LANG='scss'", "scss"],
    ["lang='s&#99;ss'", "scss"],
    ["lang='pcss'", "pcss"],
  ]) {
    const markup = "<style " + attribute + ">x</style>";
    for (const source of [markup, "{" + markup + "}"])
      assert.equal(clean(source).styles[0].lang, expected);
  }
  for (const [attribute, expected] of [
    ["", "processed-module"],
    ["type", "inline"],
    ['type=""', "inline"],
    ["type='text/javascript'", "inline"],
    ["type='application/x-javascript'", "inline"],
    ["type=' text/ecmascript '", "inline"],
    ["TYPE='module'", "module"],
    ["type={mime}", "unknown"],
    ["type='application/json'", "json"],
    ["type='application/ld+json'", "json"],
    ["type='text/partytown'", "inline"],
    ["type='text/unknown' is:inline", "unknown"],
    ["is:raw", "raw"],
  ]) {
    const markup = "<script " + attribute + ">run()</script>";
    for (const source of [markup, "{" + markup + "}"])
      assert.equal(clean(source).scripts[0].type, expected);
  }
  for (const event of [
    "onpointerdown",
    "onbeforeinput",
    "onfocusin",
    "onanimationend",
    "ontransitionend",
  ]) {
    const markup = "<button " + event + '="handle(event)" />';
    for (const source of [markup, "{" + markup + "}"])
      assert.equal(clean(source).scripts[0].content, "handle(event)");
  }
});
test("unclosed_raw_text_element_still_accounts_for_its_content", () => {
  const raw = convert("<div is:raw>lost\n<p>after</p>").code;
  contains(raw, "lost");
  contains(raw, "after");
  const style = convert("<style>.a{color:red}\n<div>after</div>");
  absent(style.code, "color:red");
  assert.equal(style.styles.length, 1);
  assert.ok(style.styles[0].content.startsWith(".a{color:red}"));
  const script = convert('<script type="application/json">{"a":1}');
  absent(script.code, '"a":1');
  assert.equal(script.scripts.length, 1);
  assert.equal(script.scripts[0].content, '{"a":1}');
});
test("unclosed_style_still_extracts_its_css", () => {
  const result = convert("<style>.a{color:red}");
  assert.equal(result.styles.length, 1);
  contains(result.styles[0].content, ".a{color:red}");
});
test("extracted_tags_carry_source_ranges", () => {
  const source =
    '---\nconst x = 1;\n---\n<style>.a{color:red}</style>\n<div onclick="go()" style="color:red"></div>\n<script>run();</script>';
  const result = convert(source);
  const slice = (range: { start: number; end: number }) => source.slice(range.start, range.end);
  assert.equal(slice(result.styles[0].position), ".a{color:red}");
  assert.equal(slice(result.styles[1].position), "color:red");
  assert.equal(slice(result.scripts[0].position), "go()");
  assert.equal(slice(result.scripts[1].position), "run();");
});
test("components_are_never_treated_as_html_script_or_style", () => {
  for (const input of [
    "<Script>alert(1)</Script>",
    "<Style>.a{color:red}</Style>",
    "{cond && <Script>alert(1)</Script>}",
  ]) {
    const result = convert(input);
    assert.equal(result.scripts.length, 0);
    assert.equal(result.styles.length, 0);
    assert.ok(result.code.includes("alert(1)") || result.code.includes("color:red"));
  }
});
test("extracted_tag_sources_slice_to_their_content", () => {
  const source =
    "---\nconst x = '𝒳';\n---\n<style>.a{background:url('𝒳.png')}</style>\n<style lang='pcss'>.b{color:red}</style>\n<div onclick=\"go('𝒳')\" style=color:red data-x='a\"b'></div>\n<script>run('𝒳');</script>\n<script>after();</script>";
  const result = convert(source);
  assert.equal(result.scripts.length, 3);
  assert.equal(result.styles.length, 3);
  assert.deepEqual(
    result.scripts.map((item) => item.content),
    ["go('𝒳')", "run('𝒳');", "after();"],
  );
  assert.equal(result.styles[0].content, ".a{background:url('𝒳.png')}");
  assert.equal(result.styles[1].lang, "pcss");
  assert.equal(result.styles[2].content, "color:red");
  for (const tag of [...result.scripts, ...result.styles])
    assert.equal(source.slice(tag.position.start, tag.position.end), tag.content);
});
test("script_types_reflect_what_is_statically_knowable", () => {
  for (const [input, expected] of [
    ["<script>const a = 1;</script>", "processed-module"],
    ['<script type="module">x</script>', "module"],
    ["<script is:inline>x</script>", "inline"],
    ["<script type={mime}>wat</script>", "unknown"],
    ["{x && <script type={mime}>wat</script>}", "unknown"],
  ])
    assert.equal(convert(input).scripts[0].type, expected);
});
test("style_languages_match_the_static_attribute_value", () => {
  for (const [attribute, expected] of [
    ["", "css"],
    ["lang={lang}", "unknown"],
    ["lang", ""],
    ['lang=""', ""],
    ['lang=" SCSS "', "scss"],
    ["lang='LeSs'", "less"],
  ])
    assert.equal(convert("<style " + attribute + ">x</style>").styles[0].lang, expected);
});
