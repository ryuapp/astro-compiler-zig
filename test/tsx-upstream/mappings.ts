import { upstream, assertMapped } from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("tests/mappings.rs", name, body);
test("attribute_names_and_values_map_back_to_source", () => {
  for (const [source, snippets] of [
    ["<div {name} />", ["name"]],
    ['<div src="" />', ['""']],
    ["---\n---\n<Tag src=`bar${foo}` />", ["foo"]],
    ['<path d="M 0\nC100 0\nZ" />', ["M 0", "C100 0", "Z"]],
    ['<div @on.click="fn" />', ["@on.click"]],
    ["<Hello></Hello>", [">", "</Hello>"]],
    ["<Button      ></Button>", [">", "</Button>"]],
  ] as [string, string[]][])
    assertMapped(source, snippets);
});
test("frontmatter_symbols_and_imports_map_back_to_source", () => {
  assertMapped("---\nnonexistent\n---\n", ["nonexistent"]);
  assertMapped(
    '---\n    /** @deprecated */\nconst deprecated = "Astro"\ndeprecated;\nconst hello = "Astro"\n---\n',
    ["deprecated;", "hello"],
  );
  assertMapped(
    '---\n    const MyVariable = "Astro"\n\n    /** Documentation */\n    const MyDocumentedVariable = "Astro"\n\n    /** @author Astro */\n    const MyJSDocVariable = "Astro"\n---\n',
    ["MyVariable", "MyDocumentedVariable", "MyJSDocVariable"],
  );
  assertMapped(
    "---\n  import { foo } from './script.js';\n    import ComponentAstro from './astro.astro';\n    import ComponentSvelte from './svelte.svelte';\n    import ComponentVue from './vue.vue';\n  import { baz } from './script';\n  foo;baz;ComponentAstro;ComponentSvelte;ComponentVue;\n---\n",
    ["'./script'", "'./astro.astro'", "'./svelte.svelte'", "'./vue.vue'"],
  );
});
test("imported_component_tags_map_back_to_source", () => {
  assertMapped(
    "---\nimport SvelteOptionalProps from './SvelteOptionalProps.svelte'\nimport SvelteError from './SvelteError.svelte'\nimport VueError from './VueError.vue'\n---\n\n<SvelteOptionalProps></SvelteOptionalProps>\n<SvelteError></SvelteError>\n<VueError></VueError>",
    ["<SvelteOptionalProps>", "<SvelteError>", "<VueError>"],
  );
});
test("template_mappings_preserve_lf_and_crlf_positions", () => {
  for (const newline of ["\n", "\r\n"])
    for (const [source, snippets] of [
      ["<div>{nonexistent}</div>", ["nonexistent"]],
      ["<div>{console.log(hey)}</div>", ["log", "hey"]],
      ['{"hello" + hey}', ["hey"]],
      ['<svg color="#000"></svg>', ["color"]],
      ['<div className="hello" />', ["className"]],
      ["<div>{\nnonexistent\n}</div>", ["nonexistent"]],
      ["<div>{\nconsole.log(hey)\n}</div>", ["log"]],
      ['{"hello" + \nhey}', ["hey"]],
      ['<svg\nvalue="foo" color="#000"></svg>', ["color"]],
      ['{[].map(ITEM => {\nv = "what";\nreturn <div>{ITEMS}</div>\n})}', ["ITEM", "ITEMS"]],
      ['<div\na="b" className="hello" />', ["className"]],
      ['<div\na="b" @on.click="fn" />', ["@on.click"]],
      ["---\nimport { Meta } from '$lib/components/Meta.astro';\n---\n", [";"]],
      ['---\nimport A from "a";\n\timport B from "b";\n---\n', ["\timport B"]],
    ] as [string, string[]][])
      assertMapped(source.replaceAll("\n", newline), snippets);
});
test("multibyte_text_and_following_content_map_back_to_source", () => {
  assertMapped("<h1>ツ</h1><p>foobar</p>", ["ツ", "foobar"]);
  assertMapped("<h1>こんにちは</h1>", ["ん", "に"]);
});
