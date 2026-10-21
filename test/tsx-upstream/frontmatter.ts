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
const test = (name: string, body: () => void) => upstream("src/render/frontmatter.rs", name, body);
test("typescript_frontmatter_is_disambiguated_as_tsx", () => {
  for (const code of [
    "const id = <T>(x: T) => x;",
    "const id = <T /* comment */>(x: T) => x;",
    "const id = <T,>(x: T) => x;",
    "const id = <T extends string>(x: T) => x;",
    "const id = <T = string>(x: T) => x;",
    "const value = <string>Astro.props.value;",
    "const value = <number><unknown>Astro.props.value;",
    "const value = (<{ x: number }>Astro.props.value).x;",
    "const value = < /* before */ string /* after */ >Astro.props.value;",
    "const value = <const>{ x: 1 };",
    "if (Astro.props.x) return <string>Astro.props.value;",
    "const id = <T>(x: T) => <T>x;",
    "const value = <string>((<T>(x: T) => x)('x'));",
  ])
    clean("---\n" + code + "\n---\n<p/>");
});
test("fences_after_markup_are_template_text", () => {
  for (const prefix of ["<!-- Copyright -->", "<div/>", "<!DOCTYPE html>"]) {
    const source = prefix + "\n---\nconst title = 'hello';\n---\n<h1>hello</h1>";
    const result = clean(source);
    assert.equal(result.frontmatterStatus, "doesnt-exist");
    assert.equal(result.frontmatter.start, result.frontmatter.end);
    contains(result.code, "---\nconst title = 'hello';\n---");
  }
});
test("frontmatter_range_is_recorded", () => {
  const result = convert("---\nlet x = 1;\n---\n<div></div>");
  assert.ok(result.frontmatter.end > result.frontmatter.start);
  contains(slice(result.code, result.frontmatter), "let x = 1;");
});
test("get_static_paths_needs_a_real_export", () => {
  const mentioned = convert(
    "---\n// see getStaticPaths in the docs\nexport const x = 1;\n---\n",
  ).code;
  absent(mentioned, "ASTRO__InferredGetStaticPath");
  contains(mentioned, "_props: Record<string, any>");
  absent(
    convert("---\nexport const handler = getStaticPaths;\n---\n").code,
    "ASTRO__InferredGetStaticPath",
  );
  for (const input of [
    "---\nexport const getStaticPaths = async () => [];\n---\n",
    "---\nexport async function getStaticPaths() { return []; }\n---\n",
    "---\nconst getStaticPaths = async () => [];\nexport { getStaticPaths };\n---\n",
  ])
    contains(convert(input).code, "ASTRO__InferredGetStaticPath");
});
test("get_static_paths_inference_requires_a_local_named_export", () => {
  for (const [frontmatter, expected] of [
    ["export const getStaticPaths = () => [];", true],
    ["export const get\\u0053taticPaths = () => [];", true],
    ["export function getStaticPaths() { return []; }", true],
    ["const getStaticPaths = () => []; export { getStaticPaths };", true],
    ["const getStaticPaths = () => []; export { getStaticPaths as getStaticPaths };", true],
    ["const getStaticPaths = () => []; export { getStaticPaths as 'getStaticPaths' };", true],
    ["const getStaticPaths = () => []; export { getStaticPaths as 'get\\u0053taticPaths' };", true],
    ["export function f(getStaticPaths) {};", false],
    ["export function f(get\\u0053taticPaths) {};", false],
    ["export function f() { function getStaticPaths() {} }", false],
    ["export function f() { const get\\u0053taticPaths = () => []; }", false],
    ["export const f = function getStaticPaths() {};", false],
    ["export class Routes { getStaticPaths() {} }", false],
    ["export default function getStaticPaths() { return []; }", false],
    ["const paths = () => []; export { paths as getStaticPaths };", false],
    ["const getStaticPaths = () => []; export { getStaticPaths as paths };", false],
    ["export { getStaticPaths } from './paths';", false],
    ["export { foo as getStaticPaths } from './paths';", false],
  ] as const) {
    const actual = convert("---\n" + frontmatter + "\n---\n").code;
    assert.equal(actual.includes("ReturnType<typeof getStaticPaths>"), expected, frontmatter);
  }
});
test("props_binding_needs_a_local_name", () => {
  for (const [input, expected] of [
    ["---\nimport Foo from './Props';\nFoo;\n---\n<div/>", false],
    ["---\nfunction DoTheThing(Props) {}\n---", false],
    ["---\nimport { Props as Other } from './t';\n---\n<div/>", false],
    ["---\nexport { Props } from './t';\n---\n<div/>", false],
    ["---\n// mentions Props only in a comment\n---\n<div/>", false],
    ["---\nimport { Other as Props } from './t';\n---\n<div/>", true],
    ["---\nimport type { Props } from './t';\n---\n<div/>", true],
    ["---\nimport Props from './t';\n---\n<div/>", true],
    ["---\nexport interface Props { a: string }\n---\n<div/>", true],
  ] as const)
    assert.equal(convert(input).code.includes("_props: Props"), expected, input);
});
test("frontmatter_is_terminated_before_the_template", () => {
  for (const frontmatter of [
    "const x = foo\n// note;",
    'console.log("hello")',
    "const { hello } = Astro.props",
  ])
    contains(
      clean("---\n" + frontmatter + "\n---\n<div class={hello}></div>").code,
      "{};<Fragment>",
    );
});
test("frontmatter_status_and_source_are_reported", () => {
  const closed = convert("---\nlet x = 1;\n---\n<p/>");
  assert.equal(closed.frontmatterStatus, "closed");
  assert.deepEqual(closed.frontmatterSource, { start: 0, end: 18 });
  assert.equal(convert("---\nlet x = 1;\n").frontmatterStatus, "open");
  assert.equal(convert("<p>hi</p>").frontmatterStatus, "doesnt-exist");
});
test("invalid_frontmatter_reports_document_relative_diagnostics", () => {
  const result = convert("---\nconst = ;\n---\n<p/>");
  assert.equal(result.hasParseErrors, true);
  assert.ok(result.diagnostics.length);
  contains(result.code, "const = ;");
  for (const diagnostic of result.diagnostics)
    assert.ok(
      diagnostic.position.start >= 4 && diagnostic.position.end <= 13,
      JSON.stringify(diagnostic),
    );
});
test("handles_non_latin_identifiers", () => {
  const frontmatter =
    "var π = Math.PI;\nvar ಠ_ಠ = eval;\nvar ლ_ಠ益ಠ_ლ = 42;\nvar λ = function() {};\nvar Ꙭൽↈⴱ = 'huh';\nvar 〱〱 = 2;\nvar Ⅳ = 4;\nvar Ⅴ = 5;\nⅣ + Ⅴ;\nvar ᱹ = 1;\nconsole.assert([1, 2, 3][ᱹ] === 2);\nvar foo\u200cbar = 42;\nvar price_9\u03369\u0336_89 = 'cheap';";
  contains(convert("---\n" + frontmatter + "\n---\n\n<div></div>\n").code, frontmatter);
});
test("handles_complex_generics", () => {
  const input =
    '---\nimport type { GetStaticPaths, MDXInstance } from "$data/shared";\n\nexport const getStaticPaths: GetStaticPaths = async () => {\n  const articles = await Astro.glob<Article>("/content/articles/**/*.mdx");\n  return articles.map((article) => {\n    return { params: { slug: getSlugFromFile(article.file) } };\n  });\n};\n\nexport interface Props {\n  article: MDXInstance<Article>;\n}\n\nconst { article } = Astro.props;\n---\n\n<ArticleLayout article={article} />';
  const result = convert(input);
  contains(result.code, "MDXInstance<Article>");
  assert.equal(result.hasParseErrors, false);
});
test("frontmatter_survives_closing_tags_in_its_code", () => {
  for (const input of [
    '---\nconst a = "</script>";\n---\n<p>x</p>',
    "---\nconst a = `</style>`;\n---\n<p>x</p>",
    "---\n// </script> in a comment\n---\n<p>x</p>",
  ]) {
    const result = convert(input);
    assert.equal(result.frontmatterStatus, "closed");
    assert.deepEqual(result.diagnostics, []);
    contains(result.code, "<p>x</p>");
  }
});
test("frontmatter_regex_containing_closing_angle_bracket", () => {
  const result = clean("---\nconst escaped = 'x'.replace(/>/g, '&gt;');\n---\n<p>{escaped}</p>");
  assert.equal(result.frontmatterStatus, "closed");
  contains(result.code, "const escaped = 'x'.replace(/>/g, '&gt;');");
  contains(result.code, "<p>{escaped}</p>");
});
test("dynamic_routes_keep_their_component_name", () => {
  for (const [filename, expected] of [
    ["src/pages/[slug].astro", "_Slug_AstroComponent"],
    ["src/pages/my-comp.astro", "MyCompAstroComponent"],
    ["src/pages/404.astro", "FourOhFourAstroComponent"],
    ["src/pages/[...path].astro", "AstroComponent"],
  ])
    contains(convert("<div/>", { filename }).code, "function " + expected + "(");
});
test("generated_get_static_paths_types_are_valid_tsx", () => {
  const input =
    "---\nexport const getStaticPaths = () => ([\n  { params: { id: '1' } }\n])\n---\n<p/>";
  const result = convert(input);
  assert.equal(result.hasParseErrors, false);
  assertSyntax(result.code);
  assertVerbatim(input, result);
});
test("bare_return_stays_terminal_for_narrowing", () => {
  const bare = convert("---\nif (cond) {\n\treturn;\n}\nreturn\n---\n<p/>").code;
  contains(bare, "throw undefined;");
  contains(bare, "throw undefined\n");
  absent(bare, "throw ;");
  absent(bare, "void 0");
  const valued = convert("---\nif (cond) return Astro.redirect('/x');\n---\n<p/>").code;
  contains(valued, "throw  Astro.redirect");
  absent(valued, "return Astro");
});
test("returns_in_default_exported_functions_are_preserved", () => {
  const actual = convert("---\nexport default function f() { return 1 }\n---\n").code;
  contains(actual, "function f() { return 1 }");
  absent(actual, "function f() { throw  1 }");
});
test("variable_length_return_rewrites_keep_runs_verbatim", () => {
  const source = "---\nconst é = 1;\nif (é) {\n\treturn;\n}\nconst after = é;\n---\n<p>{after}</p>";
  const result = convert(source);
  contains(result.code, "throw undefined;");
  contains(result.code, "const after = é;");
  assertVerbatim(source, result);
});
test("ambient_types_are_appended_only_on_request", () => {
  const source = "---\nconst title = Astro.props.title;\n---\n<h1>{title}</h1>";
  const plain = convert(source);
  absent(plain.code, "declare const Fragment");
  absent(plain.code, "declare const Astro");
  const ambient = convert(source, { ambientTypes: true });
  contains(ambient.code, "declare const Fragment: any;\n");
  contains(
    ambient.code,
    "declare const Astro: Readonly<import('astro').AstroGlobal<Record<string, any>, typeof AstroComponent>>",
  );
  assert.ok(ambient.code.startsWith(plain.code));
  assert.deepEqual(ambient.mappings, plain.mappings);
});
test("ambient_types_never_declare_astro_twice", () => {
  const source = "---\ninterface Props { title: string }\n---\n<h1>{Astro.props.title}</h1>";
  const { code } = convert(source, { ambientTypes: true });
  assert.equal(code.split("declare const Astro").length - 1, 1);
  contains(code, "AstroGlobal<Props, typeof AstroComponent>");
  assert.equal(code.split("declare const Fragment").length - 1, 1);
});
test("unicode_filenames_still_name_their_component", () => {
  contains(
    convert("<div/>", { filename: "src/components/Ünicorn.astro" }).code,
    "function ÜnicornAstroComponent(",
  );
});
