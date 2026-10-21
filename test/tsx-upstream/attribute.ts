import {
  upstream,
  assert,
  clean,
  convert,
  contains,
  absent,
  assertSyntax,
  assertVerbatim,
  assertReference,
} from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("src/render/attribute.rs", name, body);
test("attributes_preserve_expressions_in_both_contexts", () => {
  for (const name of ["value", "@x", "a:b:c", "a:", "a:1", "a:-b", "client:load.foo"])
    for (const value of ["`${foo}`", "{ok && <br>}", "{<style>.x{color:red}</style>}"]) {
      const markup = "<C " + name + "=" + value + " />";
      for (const source of [markup, "{" + markup + "}"]) {
        const result = clean(source);
        if (value.includes("foo")) contains(result.code, "`${foo}`");
        if (value.includes("style")) assert.equal(result.styles.length, 1);
      }
    }
  for (const source of [
    "<C {...{ x: <br> }} />",
    "<C x=`${<br>}` />",
    "<C {...{ x: <style>.x{color:red}</style> }} />",
  ]) {
    const result = clean(source);
    if (source.includes("style")) assert.equal(result.styles.length, 1);
  }
  for (const source of ["<C {...a ==} />", "<C @x={a ==} />", "<C x=`${a ==}` />"])
    assert.equal(convert(source).hasParseErrors, true, source);
});
test("transformed_attribute_keys_are_escaped_and_ordered", () => {
  for (const markup of [
    '<C @foo\\unicode="x" />',
    '<C @foo\\bar="x" />',
    '<C @foo="bad" {...attrs} @bar="ok" />',
  ])
    for (const source of [markup, "{" + markup + "}"]) {
      const result = clean(source);
      if (markup.includes("attrs")) {
        assert.ok(result.code.indexOf("@foo") < result.code.indexOf("...attrs"));
        assert.ok(result.code.indexOf("...attrs") < result.code.indexOf("@bar"));
      } else contains(result.code, "\\\\");
    }
});
test("embedded_opening_tag_comments_and_empty_attributes_are_valid", () => {
  clean('{<C :foo="bad" {...attrs} :bar="ok" />}');
  // The published 0.1.2 converter rejects these; the newer upstream test accepts them.
  for (const source of ["{<C {/* comment */} />}", "{<C foo={} />}"]) assertReference(source);
});
test("comment_only_attribute_values_are_undefined", () => {
  for (const name of ["foo", "@foo", "set:html"])
    for (const value of ["/* comment */", "// comment\n", "/* first */ /* second */"]) {
      const result = clean("<C " + name + "={" + value + "} />");
      contains(result.code, "void 0");
      contains(result.code, value);
    }
  for (const value of ["/* before */ value /* after */", "/* before */ /x/.test(value)"])
    absent(clean("<C foo={" + value + "} />").code, "void 0");
});
test("valueless_expression_attribute_keeps_a_value", () => {
  contains(convert("<div @click={} />").code, '{...{"@click":(void 0)}}');
});
test("transformed_attributes_preserve_each_entry", () => {
  contains(
    convert("<div @click={} @other={} />").code,
    '{...{"@click":(void 0)}} {...{"@other":(void 0)}}',
  );
  for (const input of ["<div client:load.foo @z={} />", "<div @z={} client:load.foo />"]) {
    const { code } = convert(input);
    contains(code, '{...{"@z":(void 0)}}');
    contains(code, '{...{"client:load.foo":true}}');
  }
});
test("astro_attribute_syntax_that_tsx_rejects_is_normalized", () => {
  for (const input of [
    "<Component set:html=`${content}` />",
    "<article set:text=`content` />",
    "<div class=`item-${id}` />",
    '<h1 {/* comment */} value="1">Hello</h1>',
    "<Component foo{value} />",
  ]) {
    const result = convert(input);
    assert.equal(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
    assertSyntax(result.code);
    assertVerbatim(input, result);
  }
});
test("valid_jsx_attribute_names_are_preserved", () => {
  const source = '<div 丽dfds_fsfdsfs aria-blarg name="value"></div>';
  const result = convert(source);
  contains(result.code, source);
  assertVerbatim(source, result);
});
test("dotted_attribute_names_are_lowered_to_spreads", () => {
  contains(
    clean('<div x-on:keyup.shift.enter="alert(\'Astro\')" name="value"></div>').code,
    '{...{"x-on:keyup.shift.enter":"alert(\'Astro\')"}} name="value"',
  );
});
test("spread_objects_preserve_nested_values", () => {
  for (const source of [
    '<DocSearch {...{ lang, labels: { modal, placeholder } }} client:only="preact" />',
    "<MainLayout {...Astro.props}>\n</MainLayout>",
  ])
    contains(clean(source).code, source);
});
test("single_quoted_attributes_round_trip_with_their_quotes", () => {
  const source = "<div data-x='a\"b' title='plain'></div>";
  const result = convert(source);
  contains(result.code, "data-x='a\"b'");
  assertVerbatim(source, result);
});
test("multiline_tag_headers_keep_their_whitespace", () => {
  const source = "<Comp\n  foo={bar}\n/>";
  const result = convert(source);
  contains(result.code, "foo={bar}\n/>");
  assertVerbatim(source, result);
});
test("vue_named_attributes_preserve_expressions_in_both_contexts", () => {
  for (const value of ["`${foo}`", "{ok && <br>}", "{<style>.x{color:red}</style>}"]) {
    const markup = "<C v-on:click.stop=" + value + " />";
    for (const source of [markup, "{" + markup + "}"]) {
      const result = clean(source);
      if (value.includes("foo")) contains(result.code, "`${foo}`");
      if (value.includes("style")) assert.equal(result.styles.length, 1);
    }
  }
});
test("astro_hyphenated_attributes_are_not_vue_syntax", () => {
  for (const input of ["<div v-if />", "<div v-if=visible />", "<Component v-if={visible} />"]) {
    const result = convert(input);
    assert.equal(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
    assert.deepEqual(result.diagnostics, []);
    contains(result.code, "v-if");
  }
});
test("astro_hyphenated_attribute_expressions_are_validated", () => {
  const result = convert("<Component v-if={visible ==} />");
  assert.equal(result.hasParseErrors, true);
  assert.ok(result.diagnostics.length);
});
test("v_for_attributes_preserve_their_complete_value", () => {
  for (const [input, expected] of [
    ['<div v-for="item in items" />', 'v-for="item in items"'],
    ["<div v-for=items />", 'v-for="items"'],
    ["<div v-for={items} />", "v-for={items}"],
    ["<div v-for />", "v-for"],
    ["<Component v-for={items} />", "v-for={items}"],
  ]) {
    const result = convert(input);
    assert.equal(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
    assert.deepEqual(result.diagnostics, []);
    contains(result.code, expected);
    absent(result.code, 'v-for=""');
    assertVerbatim(input, result);
  }
  const result = convert("<Component v-for={items ==} />");
  assert.equal(result.hasParseErrors, true);
  assert.ok(result.diagnostics.length);
  contains(result.code, "v-for={items ==}");
});
test("v_for_values_allow_entities_without_masking_malformed_tags", () => {
  for (const input of [
    '<div v-for="a&amp;b" />',
    "<div v-for=a&amp;b />",
    '<Component v-for="a&amp;b" />',
    "<Component v-for=a&amp;b />",
  ]) {
    const result = convert(input);
    assert.equal(result.hasParseErrors, false);
    assert.deepEqual(result.diagnostics, []);
    contains(result.code, 'v-for="a&amp;b"');
  }
  const input = '<div v-for="a&amp;b" /';
  const result = convert(input);
  assert.equal(result.hasParseErrors, true);
  assert.ok(result.diagnostics.length);
  assert.ok(result.diagnostics.every((item) => item.position.start >= input.indexOf(" /")));
});
test("v_for_expression_diagnostics_use_document_offsets", () => {
  const input = "<main><Component v-for={items ==} /></main>";
  const result = convert(input);
  const expected = input.indexOf("}");
  assert.ok(result.diagnostics.length);
  const diagnostic = result.diagnostics.at(-1)!;
  assert.deepEqual(diagnostic.position, { start: expected, end: expected });
  assert.equal(sliceSource(input, diagnostic.position), "");
});
function sliceSource(source: string, range: { start: number; end: number }) {
  return source.slice(range.start, range.end);
}
test("v_for_uses_the_complete_expression_boundary", () => {
  for (const value of [
    "{a: 1}",
    "items.map(x => ({x}))",
    'fn("}")',
    "`item-${items.map(x => ({x}))}`",
    "items.map(/* } */ x => ({x}))",
    "items.filter(x => /}/.test(x))",
  ]) {
    const input = "<Component v-for={" + value + '} data-after="yes" />';
    const result = convert(input);
    assert.equal(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
    assert.deepEqual(result.diagnostics, []);
    contains(result.code, "v-for={" + value + "}");
    contains(result.code, 'data-after="yes"');
    assertVerbatim(input, result);
  }
  const input = '<Component v-for={items.map(x => ({x})} data-after="yes" />';
  const result = convert(input);
  assert.equal(result.hasParseErrors, true);
  assert.ok(result.diagnostics.length);
  contains(result.code, "v-for={items.map(x => ({x})}");
  contains(result.code, 'data-after="yes"');
  assertVerbatim(input, result);
});
test("invalid_attribute_string_values_are_javascript_escaped", () => {
  for (const input of [
    "<Component @event='quote\" slash\\ line\n\u2028\u2029\t' />",
    "{ok && <Component @event='quote\" slash\\ line\n\u2028\u2029\t' />}",
  ])
    contains(convert(input).code, '{...{"@event":"quote\\" slash\\\\ line\\n\\u2028\\u2029\\t"}}');
});
test("invalid_attribute_string_values_are_html_decoded", () => {
  const encoded =
    "&NotEqualTilde; &#128; &#0; &#xD800; &#x110000; &copy &amp; &quot; &copycat &amp= &bogus;";
  const decoded = '≂̸ € � � � © & \\" &copycat &amp= &bogus;';
  const markup = "<Component @event='" + encoded + "' />";
  for (const input of [markup, "{ok && " + markup + "}"]) {
    const result = convert(input);
    contains(result.code, '{...{"@event":"' + decoded + '"}}');
    assertVerbatim(input, result);
  }
});
