import type { ConvertToTsxOptions } from "../../src/types.ts";

export const categories = [
  "combination",
  "frontmatter",
  "filename",
  "truncated",
  "deleted",
] as const;
export type Category = (typeof categories)[number];
export type Input = { category: Category; source: string; options?: ConvertToTsxOptions };
export const inputs: Input[] = [];
const seen = new Set<string>();
function add(category: Category, source: string, options?: ConvertToTsxOptions) {
  const key = JSON.stringify([source, options]);
  if (!seen.has(key)) {
    seen.add(key);
    inputs.push({ category, source, options });
  }
}
for (const tag of ["div", "Component", "textarea", "title", "script", "style", "math", "iframe"]) {
  for (const attrs of [
    "",
    " flag",
    ' name="a&amp;b"',
    ' @x="a&amp;b"',
    " value={a,b}",
    " @x={ a,b }",
    " value={/*x*/}",
    " @x={/*x*/}",
    " @x=`item-${n}`",
    " {...{title:<span/>}}",
    " {name}",
    ' lang="scss" type="module"',
  ]) {
    for (const body of [
      "",
      "hello",
      "{x}",
      "a < b",
      "<span>{x}</span>",
      "<!--c-->",
      "日本🦊",
      "<style>.x{color:red}</style>",
      "<script>run()</script>",
      "{ok && <br>}",
    ]) {
      const markup = "<" + tag + attrs + ">" + body + "</" + tag + ">";
      for (const source of [markup, "{ok && " + markup + "}"]) {
        add("combination", source);
        add("frontmatter", "---\nconst x = 1;\n---\n" + source);
      }
    }
  }
}
for (const filename of [
  "foo.astro",
  "my_comp.astro",
  "my__comp.astro",
  "$foo.astro",
  "foo$bar.astro",
  "foo2bar.astro",
  "foo2Bar.astro",
  "FOOBar.astro",
  "myCOMP.astro",
  "iPhone.astro",
  "a.b.astro",
  "[slug].astro",
  "[...slug].astro",
  "some/path/",
  "some/path/.astro",
  "éComp.astro",
  "ΔPage.astro",
  "straße.astro",
  "İstanbul.astro",
  "a\u0301b.astro",
  "ßPage.astro",
  "my\u2014page.astro",
  "my\u203fpage.astro",
]) {
  add("filename", "<p/>", { filename });
  add("filename", "---\ninterface Props<T> {value:T}\n---\n<p/>", { filename, ambientTypes: true });
}
for (const source of [
  "<div><span>x</span></div>",
  "{ok && <Component @x={a,b} />}",
  '<script>const x = "🦊";</script>',
  "<style>.x{color:red}</style>",
  "<textarea><b>{x}</b></textarea>",
  "---\nconst id = <T>(x:T)=>x;\n---\n<p>{id(x)}</p>",
  "---\ninterface Props<T> {x:T}\n---\n<Component value={Astro.props.x} />",
  '<div lang="日本" onclick="run()">🦊</div>',
]) {
  const chars = Array.from(source);
  for (let end = 0; end <= chars.length; end++) add("truncated", chars.slice(0, end).join(""));
  for (let position = 0; position < chars.length; position++)
    add("deleted", chars.slice(0, position).join("") + chars.slice(position + 1).join(""));
}
