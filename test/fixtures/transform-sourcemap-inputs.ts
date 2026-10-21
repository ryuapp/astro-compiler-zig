export const errorProbes = [
  ["frontmatter", '---\nfunction fail() {\n  throw new Error("marker");\n}\n---\n{fail()}'],
  ["arrow-expression", '<p>{(() => {\n  throw new Error("marker");\n})()}</p>'],
  ["function-expression", '<p>{(function() {\n  throw new Error("marker");\n})()}</p>'],
  ["object-method", '<p>{({ run() {\n  throw new Error("marker");\n} }).run()}</p>'],
  ["nested-condition", '<p>{(() => {\n if (true) {\n  throw new Error("marker");\n }\n})()}</p>'],
  ["async-function-expression", '<p>{(async function() {\n  throw new Error("marker");\n})()}</p>'],
  [
    "crlf-unicode",
    '---\r\nconst text="🦊日本語";\r\nfunction fail() {\r\n  throw new Error(text);\r\n}\r\n---\r\n{fail()}',
  ],
  ["binary-expression", '<p>{1 + (function() {\n  throw new Error("marker");\n})()}</p>'],
  ["getter", '<p>{({ get value() {\n  throw new Error("marker");\n} }).value}</p>'],
  ["class-method", '<p>{new (class { run() {\n  throw new Error("marker");\n} })().run()}</p>'],
  [
    "conditional-inline-script",
    '<head>🦊\r\n{true && (<script is:inline set:html={"raw"} />)}\r\n{(() => {\r\n  throw new Error("marker");\r\n})()}</head>',
  ],
] as const;

export const pathSource =
  '---\nimport C from "./C.jsx";\nimport D from "./D.jsx";\n---\n<C client:load/><p>{__first}</p>\n<D client:visible/><p>{__second}</p>\n<C client:idle/><p>{__third}</p>';

export const resolvedPaths = [
  "/very/long/resolved/path/to/",
  "/",
  '/日本語/🦊/"quoted"\\path\n\r\t/',
  "/separator\u2028paragraph\u2029/",
];
