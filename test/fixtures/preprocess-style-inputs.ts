export const styleInputs = [
  { name: "no styles", source: "<p>Hello</p>" },
  { name: "empty source", source: "" },
  { name: "raw CSS", source: "<style>\r\n p {content: '🦊日本語 &amp;';}\r\n</style>" },
  { name: "empty and self-closing", source: "<style/><style></style><style>p{color:red}</style>" },
  {
    name: "attributes",
    source:
      '<style lang=scss is:global data_x="a&amp;b" title="x&#x1F98A;" define:vars={{x:1}} {...props}>$color:red;</style>',
  },
  {
    name: "duplicate and object property attributes",
    source: '<style a="one" a="two" __proto__="test" constructor="ctor">p{color:red}</style>',
  },
  { name: "attribute escapes", source: '<style lang="s\\ncss" title="🦊\r\n日本語">p{}</style>' },
  {
    name: "inline and content directives",
    source:
      "<style is:inline>inline</style><style set:html={css}/><style set:text={css}/><style>p{}</style>",
  },
  {
    name: "non-hoistable ancestors",
    source:
      "<svg><g><style>svg</style></g></svg><noscript><div><style>noscript</style></div></noscript><template><style>template</style></template><style>p{}</style>",
  },
  {
    name: "fragments and components",
    source: "<><Card><style>a{}</style></Card><div><style>b{}</style></div></>",
  },
  {
    name: "embedded expressions and frontmatter markup",
    source:
      "---\nconst render = () => <style>frontmatter</style>;\n---\n{true && <style>expression</style>}<style>p{}</style>",
  },
  {
    name: "comments and scripts",
    source:
      '<!-- <style>comment</style> --><script>const x="<style>script</style>";</script><style>p{}</style>',
  },
  {
    name: "exact tag names",
    source: "<STYLE>upper</STYLE><Style>component</Style><style is:raw>p{}</style>",
  },
  { name: "invalid CSS is passed through", source: "<style lang=scss>p{unclosed</style>" },
  { name: "invalid frontmatter", source: "---\nconst x=;\n---\n<style>p{}</style>" },
  { name: "invalid expression", source: "<p>{broken + }</p><style>p{}</style>" },
  { name: "unclosed style", source: "<style>p{}" },
] as const;

export function* generatedStyleInputs() {
  const attributes = [
    "",
    ' lang="scss"',
    " lang=scss",
    " is:global",
    ' is:global="true"',
    " is:inline",
    " is:inline={false}",
    " set:html={css}",
    " set:text={css}",
    ' define:vars={{ color: "red" }}',
    " {...props}",
    " {lang}",
    " data-x={`hello`}",
    ' LANG="scss"',
    " is:raw",
    ' a="1" a="2"',
    ' title="&amp;&#x1f98a;\\n"',
    ' __proto__="abc" constructor="value" toString="str"',
    ' data_a="x"',
    ' lang = "scss"',
    ' /* comment */ lang="scss"',
    ' lang="a\r\nb"',
  ];
  const bodies = [
    "",
    "p{color:red}",
    '\r\n a{content:"🦊日本語";}\r\n',
    "<!--x-->",
    'a{content:"</STYLE>"}',
    'a{content:"</style >"}',
    "\0x",
    "&amp; {x} <b>x</b>",
    "🦊\ud800",
  ];
  const contexts = [
    (style: string) => style,
    (style: string) => `<div>${style}</div>`,
    (style: string) => `<>${style}</>`,
    (style: string) => `<Card>${style}</Card>`,
    (style: string) => `<svg><g>${style}</g></svg>`,
    (style: string) => `<svg><foreignObject>${style}</foreignObject></svg>`,
    (style: string) => `<template><div>${style}</div></template>`,
    (style: string) => `<noscript>${style}</noscript>`,
    (style: string) => `<textarea>${style}</textarea>`,
    (style: string) => `<script type="text/plain">${style}</script>`,
    (style: string) => `{true && (${style})}`,
    (style: string) => `{[${style}]}`,
    (style: string) => `---\nconst render=()=>${style};\n---\n<style>end</style>`,
    (style: string) => `---\nconst x: number = 1;\n---\n${style}`,
    (style: string) => `<head>${style}</head><style>end</style>`,
  ];
  for (const attr of attributes)
    for (const body of bodies)
      for (const [context, wrap] of contexts.entries())
        for (const tail of ["", "<style>tail{}</style>"]) {
          const source = wrap(`<style${attr}>${body}</style>`) + tail;
          yield { name: `${context}:${JSON.stringify(source)}`, source };
        }
}
