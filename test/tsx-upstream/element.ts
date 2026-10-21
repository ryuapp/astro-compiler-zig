import {
  upstream,
  assert,
  clean,
  convert,
  contains,
  absent,
  slice,
  assertSyntax,
  assertVerbatim,
} from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("src/render/element.rs", name, body);
test("body_range_is_recorded", () => {
  const result = convert("<h1>Hi</h1>");
  assert.ok(result.body.end > result.body.start);
  contains(slice(result.code, result.body), "<h1>");
  contains(slice(result.code, result.body), "</h1>");
});
test("tag_headers_and_leading_fragments_preserve_whitespace", () => {
  for (const source of [
    "<Button ></Button>",
    '<Button a="b" ></Button>',
    "<Button      ></Button>",
    "<Button\n\t></Button>",
    "\n<>Test123</>",
  ])
    contains(clean(source).code, source);
});
test("jsx_comments_preserve_surrounding_whitespace", () => {
  for (const comment of ["/* @ts-expect-error */", "// @ts-expect-error"])
    for (const source of [
      "{\n" + comment + '\n}\n<Component prop="value"></Component>',
      "{\n" + comment + '\n<Component prop="value"></Component>\n}',
    ])
      contains(clean(source).code, source);
  const source = '{/* @ts-expect-error */}\n<Component prop="value"></Component>';
  contains(clean(source).code, source);
});
test("comments_before_the_first_element_survive", () => {
  for (const input of [
    "<!-- leading -->\n<div>x</div>",
    "---\nconst a = 1;\n---\n<!-- between -->\n<div>x</div>",
  ]) {
    const { code } = convert(input);
    assert.ok(code.includes("{/** leading */}") || code.includes("{/** between */}"), code);
    absent(code, "<!--");
  }
});
test("doctype_never_reaches_the_output", () => {
  for (const input of [
    "<!doctype html>\n<html><body>x</body></html>",
    "<!DOCTYPE html>\n<html><body>x</body></html>",
    '---\nconst a = 1;\n---\n\n<!doctype html>\n<html lang="en"><body>{a}</body></html>\n',
    "---\nconst a = 1;\n---\n<!doctype html>",
    "<div>hi</div>\n<!DOCTYPE html>\n<p>after</p>",
    "<!DOCTYPE html>\n<!DOCTYPE html>\n<p/>",
    "<main>\n<!doctype html>\n<p>x</p>\n</main>",
  ])
    absent(convert(input).code, "<!");
  contains(convert("<!doctype html>\n<html><body>x</body></html>").code, "<html>");
  contains(convert("<div>hi</div>\n<!DOCTYPE html>\n<p>after</p>").code, "<p>after</p>");
});
test("bare_less_than_in_text_is_escaped", () => {
  for (const input of ["<p>a < b</p>", "<div>5 < 10 is true</div>"]) {
    const result = convert(input);
    contains(result.code, "{`<`}");
    assert.equal(result.hasParseErrors, false);
    assertVerbatim(input, result);
  }
});
test("astro_text_that_is_not_tsx_text_is_escaped", () => {
  for (const input of [
    "<math><annotation>f\\colon X \\to \\mathbb{R}^{2x}</annotation></math>",
    "<日本>hi</日本>",
  ]) {
    const result = convert(input);
    assert.equal(result.hasParseErrors, false);
    assertSyntax(result.code);
    assertVerbatim(input, result);
  }
  for (const element of [
    "iframe",
    "noembed",
    "noframes",
    "plaintext",
    "textarea",
    "title",
    "xmp",
  ]) {
    const input = "<" + element + ">{value} with <b>tags</b></" + element + ">";
    const result = clean(input);
    contains(
      result.code,
      ["title", "textarea"].includes(element)
        ? "{value} with {`<`}b{`>`}tags{`<`}/b{`>`}"
        : "{`{value} with <b>tags</b>`}",
    );
  }
  for (const element of ["pre", "listing"]) {
    const input = "<" + element + ">{value} with <b>tags</b></" + element + ">";
    const result = convert(input);
    contains(result.code, "{value} with <b>tags</b>");
    assertVerbatim(input, result);
  }
});
test("text_only_elements_preserve_expressions_inside_literal_tags", () => {
  for (const tag of ["title", "textarea"])
    for (const body of [
      "<b>{value}</b>",
      "<b><i>{value}</i></b>",
      "\n <b>\n {value} \n </b> \n",
      "<Widget>{value}</Widget>",
      "<b>{value}</b>{other}",
      "<b>{ok && <span>{value}</span>}</b>",
    ]) {
      const markup = "<" + tag + ">" + body + "</" + tag + ">";
      for (const source of [markup, "{" + markup + "}"]) {
        const result = clean(source);
        contains(result.code, "{value}");
        absent(result.code, "<b>");
        absent(result.code, "<Widget>");
        if (body.includes("other")) contains(result.code, "{other}");
        if (body.includes("span")) contains(result.code, "<span>{value}</span>");
      }
    }
});
test("unclosed_text_only_elements_keep_literal_content", () => {
  for (const tag of ["title", "textarea"]) {
    const source = "<" + tag + ">before <b>after</b>";
    const result = convert(source);
    contains(result.code, "before {`<`}b{`>`}after{`<`}/b{`>`}");
    assertVerbatim(source, result);
  }
});
test("raw_template_escapes_are_present_but_unmapped", () => {
  const source = "<div is:raw>a`b ${x}</div>";
  const result = convert(source);
  contains(result.code, "{`a\\`b \\${x}`}");
  assertVerbatim(source, result);
});
