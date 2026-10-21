import { upstream, assert, clean, convert, contains, absent } from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("src/expression.rs", name, body);
test("raw_element_references_are_not_javascript", () => {
  for (const markup of [
    "<math>{R}</math>",
    "<math><mi>{R}</mi></math>",
    "<textarea><Widget /></textarea>",
  ])
    for (const source of [markup, "{" + markup + "}"]) {
      const result = clean(source);
      absent(result.code, "{R}");
      absent(result.code, "<Widget");
    }
});
test("unparseable_expression_bodies_are_not_silent", () => {
  assert.equal(convert("<div>{x ==}</div>").hasParseErrors, true);
  assert.equal(convert("<div>{}</div>").hasParseErrors, false);
});
test("expression_string_literals_keep_their_value", () => {
  for (const value of ['"<br/>"', "'<b>y</b>'", "`<b>y</b>`"])
    contains(convert("<div>{" + value + "}</div>").code, "{" + value + "}");
});
test("expression_generics_are_not_markup", () => {
  for (const value of ["foo<Bar>(x)", "a.b<C<D>>(y)"])
    contains(convert("<div>{" + value + "}</div>").code, "{" + value + "}");
});
test("only_adjacent_siblings_are_wrapped_in_a_fragment", () => {
  contains(
    convert("<div>{c && <span>a</span> <span>b</span>}</div>").code,
    "{c && <Fragment><span>a</span> <span>b</span></Fragment>}",
  );
  for (const input of [
    "<div>{c && <span>a</span>}</div>",
    "<div>{l.map(i => <span>{i}</span>)}</div>",
  ])
    absent(convert(input).code, "<Fragment><span");
});
test("html_comments_inside_expressions_become_jsx_comments", () => {
  for (const input of [
    "{list.map(() => <Component><!--Hi--></Component>)}",
    "<div>{x && <span><!--hi--></span>}</div>",
  ]) {
    const result = convert(input);
    absent(result.code, "<!--");
    contains(result.code, "{/**");
  }
});
