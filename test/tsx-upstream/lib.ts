import { upstream, assert, convert, contains, absent, slice, assertVerbatim } from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("src/lib.rs", name, body);
const prefix = "/* @jsxImportSource astro */\n\n";
test("generated_export_ranges_point_to_component_exports", () => {
  const source =
    "---\nconst marker = 'MyPageAstroComponent 𝒳';\ninterface Props<T> { value: T }\n---\n<p>{marker}</p>";
  for (const [filename, component, alias] of [
    ["MyPage.astro", "MyPageAstroComponent", "MyPage"],
    ["[slug].astro", "_Slug_AstroComponent", undefined],
    ["404.astro", "FourOhFourAstroComponent", undefined],
    ["[...path].astro", "AstroComponent", undefined],
    ["Ünicorn.astro", "ÜnicornAstroComponent", undefined],
  ]) {
    const result = convert(source, { filename, ambientTypes: true });
    assert.equal(result.hasParseErrors, false);
    const mapping = result.mappings.find((item) => item[4] === 1 && item[5] === 72);
    assert.ok(mapping);
    assert.equal(result.code.slice(mapping[0], mapping[0] + mapping[1]), component);
    contains(result.code, "'MyPageAstroComponent 𝒳'");
    contains(result.code, "Parameters<typeof " + component + ">[0]");
    if (alias) {
      const range = result.generatedComponentExport;
      assert.ok(range);
      assert.equal(slice(result.code, range), "export { " + component + " as " + alias + " };\n");
      assert.equal(range.end, result.code.length);
      assert.ok(range.start >= result.body.end && range.start >= result.frontmatter.end);
    } else {
      assert.equal(result.generatedComponentExport, undefined);
      absent(result.code, "export {");
    }
    assertVerbatim(source, result);
  }
});
test("missing_frontmatter_records_a_generated_completion_slot", () => {
  const result = convert("<Ima");
  assert.equal(result.frontmatterStatus, "doesnt-exist");
  assert.equal(result.frontmatter.start, result.frontmatter.end);
  const insertion = result.mappings.find((item) => item[4] === 1 && item[5] === 4);
  assert.ok(insertion);
  assert.equal(insertion[0] + insertion[1], result.frontmatter.start);
  assert.equal(result.code.slice(insertion[0], insertion[0] + insertion[1]), "\n");
  assert.ok(
    result.mappings.some((item) => item[0] === result.body.start && item[2] === 0 && item[4] === 0),
  );
  const withFrontmatter = convert("---\n---\n\n<Ima");
  assert.equal(withFrontmatter.frontmatterStatus, "closed");
  assert.ok(!withFrontmatter.mappings.some((item) => item[4] === 1 && item[5] === 4));
});
test("frontmatter_terminator_is_mapped_to_the_closing_fence", () => {
  const source =
    "---\nimport Hello from './Hello.astro'\nimport Layout from './Layout.astro'\n---\n<Layout><Hello /></Layout>";
  const result = convert(source);
  assert.equal(result.hasParseErrors, false);
  assert.equal(result.code.slice(result.frontmatter.end, result.body.start), ";{};<Fragment>\n");
  assert.ok(
    result.mappings.some(
      (item) =>
        item[0] === result.frontmatter.end &&
        item[2] === source.lastIndexOf("---") &&
        item[4] === 1,
    ),
  );
});
test("named_component_exports_do_not_replace_explicit_exports", () => {
  for (const declaration of [
    "export const MyPage = 1;",
    "export function MyPage() {}",
    "export class MyPage {}",
    "export enum MyPage { Value }",
    "export namespace MyPage { export const value = 1; }",
    "export declare const MyPage: number;",
    "export declare function MyPage(): void;",
    "export interface MyPage { value: string }",
    "export type MyPage = string;",
    "export const { nested: [MyPage] } = data;",
    "const MyPage = 1; export { MyPage };",
    "const value = 1; export { value as MyPage };",
    "export { value as MyPage } from './other';",
    "export { MyPage } from './other';",
    "export * as MyPage from './other';",
    "export const MyP\\u0061ge = 1;",
    "const value = 1; export { value as 'MyPage' };",
  ]) {
    const source = "---\n" + declaration + "\n---";
    const result = convert(source, { filename: "MyPage.astro" });
    assert.equal(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
    assert.equal(result.generatedComponentExport, undefined);
    contains(result.code, "export default function MyPageAstroComponent(");
    contains(result.code, declaration);
    assertVerbatim(source, result);
  }
  for (const declaration of [
    "const MyPage = 1;",
    "export const value = () => { const MyPage = 1; return MyPage; };",
    "export const { value = (() => { const MyPage = 1; return MyPage; })() } = data;",
    "export const { MyPage: value } = data;",
    "const MyPage = 1; export { MyPage as other };",
    "export { MyPage as other } from './other';",
    "export * from './other';",
  ]) {
    const source = "---\n" + declaration + "\n---";
    const result = convert(source, { filename: "MyPage.astro" });
    assert.equal(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
    assert.ok(result.generatedComponentExport);
    assertVerbatim(source, result);
  }
});
test("diagnostics_stay_within_source_for_every_truncation", () => {
  for (const source of [
    "   ---\n`t a=1",
    "---\nconst é = `𝒳${a}`;\n---\n<p>{a}</p>",
    "<C v-for={items.map(x => ({x}))} @x=`${foo}` />",
    "{<div><!-- comment --><C x={a} /></div>}",
  ]) {
    const inputs = [""];
    let input = "";
    for (const character of source) {
      input += character;
      inputs.push(input);
    }
    for (const input of inputs) {
      const result = convert(input);
      for (const diagnostic of result.diagnostics) {
        const { start, end } = diagnostic.position;
        assert.ok(start <= end && end <= input.length, JSON.stringify({ input, diagnostic }));
        for (const offset of [start, end])
          assert.ok(
            !(
              offset > 0 &&
              offset < input.length &&
              /[\uD800-\uDBFF]/.test(input[offset - 1]) &&
              /[\uDC00-\uDFFF]/.test(input[offset])
            ),
          );
      }
      assertVerbatim(input, result);
    }
  }
});
test("parser_errors_surface_but_do_not_block_emission", () => {
  const result = convert("---\nconst items = [1];\n---\n{items.map(i => <div>{i}</div>)");
  assert.equal(result.hasParseErrors, true);
  assert.ok(result.code.startsWith(prefix));
});
test("diagnostics_carry_positions_pointing_at_the_problem", () => {
  const source = "<div>{x ==}</div>";
  const result = convert(source);
  assert.ok(result.diagnostics.length);
  for (const diagnostic of result.diagnostics) {
    assert.ok(diagnostic.message.length);
    assert.ok(
      diagnostic.position.start <= diagnostic.position.end &&
        diagnostic.position.end <= source.length,
    );
  }
});
test("malformed_comments_and_fragments_report_the_offending_line", () => {
  for (const [line, problem] of [
    ["      {/*", "/*"],
    ['    < data-test="hello"><div></div></>', "</>"],
  ]) {
    const source =
      "<html>\n  <head>\n    <title>Hello world</title>\n  </head>\n  <body>\n" +
      line +
      "\n  </body>\n</html>";
    const result = convert(source);
    assert.equal(result.hasParseErrors, true);
    contains(result.code, line);
    const start = source.indexOf(problem);
    assert.ok(
      result.diagnostics.some(
        (item) => item.position.start <= start && item.position.end > start && item.message.length,
      ),
      JSON.stringify(result.diagnostics),
    );
    assertVerbatim(source, result);
  }
});
test("tolerates_line_separators", () => {
  for (const input of [
    " ",
    "something something",
    "something  ",
    "   ",
    "\u2028",
    "something\u2029something",
    "something\u2028\u2029",
    "\u2028\u2029\u2028",
  ])
    assert.ok(convert(input).code.startsWith(prefix));
});
test("malformed_input_never_panics_in_the_parser", () => {
  for (const input of ["<div></{<//", "<a></", "</", "<//", "<div></{", "{<//}"])
    assert.ok(convert(input).code.startsWith(prefix));
});
test("unclosed_elements_are_emitted_as_written_and_flagged", () => {
  for (const input of [
    "<div>hello",
    "<Card>\n  <p>text</p>",
    "<p>one<p>two",
    "<>{1}<p>x</p>",
    "<table><tr><td>a<td>b</tr></table>",
    "<div>x</div",
    "<>x",
    "<img /",
    "<components.",
    "<myMarkdown.\n",
    "<div></div>\n<div",
    "<div>\n<div\n</div>\n",
    "<div class={",
    "<div class=`></div>\n  ",
    '<main id="gotcha />',
    "<main id='gotcha/>",
    "<div>{[].map((something) => <div><Blocknote</div><div><Image</div>)}</div>",
  ]) {
    const result = convert(input);
    contains(result.code, input.startsWith("<table>") ? "<td>a<td>b</tr></table>" : input);
    assert.ok(!result.code.includes("</div>") || input.includes("</div>"));
    assert.equal(result.hasParseErrors, true, input);
    assertVerbatim(input, result);
  }
  absent(convert("<div>x</div").code, "</div>");
  absent(convert("<>x").code, "</>");
});
