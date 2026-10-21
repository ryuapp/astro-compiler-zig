import { assert, test as module1 } from "vite-plus/test";
import { parse } from "./parse-internal.ts";
const test = module1;
const NULL = 0xffffffff;
const view = (ast: any, root: any) => ({ ...ast.tree, root });
function payload(tree: any, id: number, tag: any) {
  const data = tree.nodes[id!].data;
  assert.deepEqual(Object.keys(data), [tag]);
  return data[tag];
}
function entries(tree: any, range: any) {
  return tree.extras.slice(range.start, range.start + range.len);
}
function stringBytes(tree: any, handle: any) {
  const source = Buffer.from(tree.source);
  return handle.start < source.length
    ? source.subarray(handle.start, handle.end)
    : Buffer.from(tree.strings.extra).subarray(
        handle.start - source.length,
        handle.end - source.length,
      );
}
test("frontmatter keeps Yuku declarations, child IDs, type fields and literal kinds", () => {
  const source = "---\nconst x: number = 0xFF;\n---\n<p>{x + 1}</p>";
  const result = parse(source);
  assert.deepEqual(result.diagnostics, [] as any[]);
  const tree = view(result.ast, result.ast.frontmatter!.root);
  const program = payload(tree, tree.root, "program");
  assert.strictEqual(program.source_type, "module");
  assert.strictEqual(program.hashbang, null);
  const declaration = payload(tree, entries(tree, program.body)[0], "variable_declaration");
  assert.strictEqual(declaration.kind, "const");
  assert.strictEqual(declaration.declare, false);
  const declarator = payload(
    tree,
    entries(tree, declaration.declarators)[0],
    "variable_declarator",
  );
  assert.strictEqual(declarator.definite, false);
  const binding = payload(tree, declarator.id, "binding_identifier");
  assert.strictEqual(stringBytes(tree, binding.name).toString(), "x");
  assert.strictEqual(binding.optional, false);
  const annotation = payload(tree, binding.type_annotation, "ts_type_annotation");
  assert.deepEqual(payload(tree, annotation.type_annotation, "ts_number_keyword"), {});
  const literal = payload(tree, declarator.init, "numeric_literal");
  assert.deepEqual(Object.keys(literal), ["kind", "raw"]);
  assert.strictEqual(literal.kind, "hex");
  assert.strictEqual(stringBytes(tree, literal.raw).toString(), "0xFF");
  assert.strictEqual(tree.source, source);
  assert.strictEqual(tree.lang, "tsx");
  assert.ok(tree.tokens.length > 0);
  assert.ok(tree.tokens.some((token: any) => token.tag === "eof"));
});
test("expressions keep Yuku root IDs, enum names and operator operands", () => {
  const { ast, diagnostics } = parse("{left + right}");
  assert.deepEqual(diagnostics, [] as any[]);
  const tree = view(ast, ast.template.nodes[ast.template.rootIds[0]].javascript);
  const binary = payload(tree, tree.root, "binary_expression");
  assert.strictEqual(binary.operator, "add");
  for (const [id, name] of [
    [binary.left, "left"],
    [binary.right, "right"],
  ]) {
    assert.strictEqual(
      stringBytes(tree, payload(tree, id, "identifier_reference").name).toString(),
      name,
    );
  }
  assert.deepEqual(tree.nodes[tree.root].span, { start: 1, end: 13 });
  assert.strictEqual(tree.tokens.length, 4);
  assert.strictEqual(tree.tokens.at(-2).tag, "identifier");
  assert.strictEqual(tree.tokens.at(-1).tag, "eof");
});
test("function flags, formal parameter ranges and absent NodeIndex values survive", () => {
  const { ast, diagnostics } = parse(
    "---\nexport async function* f<T>(x?: T): T { return x!; }\n---\n",
  );
  assert.deepEqual(diagnostics, [] as any[]);
  const tree = view(ast, ast.frontmatter!.root);
  const fn = tree.nodes.find((node: any) => node.data.function).data.function;
  assert.strictEqual(fn.type, "function_declaration");
  assert.strictEqual(fn.async, true);
  assert.strictEqual(fn.generator, true);
  assert.strictEqual(fn.declare, false);
  const parameters = payload(tree, fn.params, "formal_parameters");
  assert.strictEqual(parameters.rest, NULL);
  const parameter = payload(tree, entries(tree, parameters.items)[0], "formal_parameter");
  assert.strictEqual(payload(tree, parameter.pattern, "binding_identifier").optional, true);
  assert.ok(tree.nodes[fn.type_parameters].data.ts_type_parameter_declaration);
  assert.ok(tree.nodes[fn.return_type].data.ts_type_annotation);
});
test("decoded strings preserve Yuku pool bytes including lone surrogates", () => {
  const { ast, diagnostics } = parse('{"a\\n\\uD800"}{0b101n}');
  assert.deepEqual(diagnostics, [] as any[]);
  const first = view(ast, ast.template.nodes[ast.template.rootIds[0]].javascript);
  const literal = payload(first, first.root, "string_literal");
  assert.deepEqual([...stringBytes(first, literal.value)], [0x61, 0x0a, 0xed, 0xa0, 0x80]);
  assert.strictEqual(stringBytes(first, literal.raw).toString(), '"a\\n\\uD800"');
  const second = view(ast, ast.template.nodes[ast.template.rootIds[1]].javascript);
  assert.strictEqual(
    stringBytes(second, payload(second, second.root, "bigint_literal").raw).toString(),
    "0b101",
  );
  assert.strictEqual(first.nodes, second.nodes);
  assert.strictEqual(first.strings, second.strings);
  // The document owns its strings after another parse and GC.
  for (let i = 0; i < 30; i++) parse("{other + value}");
  if (global.gc) global.gc?.();
  assert.deepEqual([...stringBytes(first, literal.value)], [0x61, 0x0a, 0xed, 0xa0, 0x80]);
});
test("empty comment expressions retain null roots and original Yuku comments", () => {
  const { ast, diagnostics } = parse("{/* retained */}{}");
  assert.deepEqual(diagnostics, [] as any[]);
  for (const id of ast.template.rootIds)
    assert.strictEqual(ast.template.nodes[id!].javascript, NULL);
  const tree = ast.tree;
  assert.strictEqual(tree.comments.length, 1);
  assert.strictEqual(tree.comments[0].type, "block");
  assert.strictEqual(stringBytes(tree, tree.comments[0].value).toString(), " retained ");
  assert.deepEqual(tree.comments[0].span, { start: 1, end: 15 });
  assert.deepEqual(
    tree.tokens.map((token: any) => token.tag),
    ["eof"],
  );
});
test("dialect nodes preserve Yuku children and link directly to native Astro views", () => {
  const { ast, diagnostics } = parse(
    "---\nconst view = () => <Card>{value}</Card>;\n---\n{items.map(x => <li>{x}</li>)}",
  );
  assert.deepEqual(diagnostics, [] as any[]);
  const tree = ast.tree;
  assert.strictEqual(tree.markup.length, 4);
  const binding = tree.markup.find((link) => ast.template.nodes[link.astro_node].name === "Card");
  assert.ok(binding);
  assert.strictEqual(tree.nodes[binding.node].data.dialect.kind, "component");
  const link = tree.markup.find((link) => ast.template.nodes[link.astro_node].name === "li");
  assert.ok(link);
  const node = ast.template.nodes[link.astro_node];
  assert.strictEqual(node.name, "li");
  assert.deepEqual(tree.nodes[link.node].span, { start: node.start, end: node.end });
});
test("script programs and generic component types share the document Yuku tree", () => {
  const { ast, diagnostics } = parse(
    "<script>const x: number = 1;</script><X<Map<string, number>>/>",
  );
  assert.deepEqual(diagnostics, [] as any[]);
  const [script, component] = ast.template.rootIds.map((id) => ast.template.nodes[id!]);
  assert.ok(ast.tree.nodes[script.javascript!].data.program);
  const types = view(ast, component.typeArguments);
  const typeArguments = payload(types, types.root, "ts_type_parameter_instantiation");
  assert.ok(types.nodes[entries(types, typeArguments.params)[0]].data.ts_type_reference);
  assert.strictEqual(types.lang, "tsx");
  assert.notStrictEqual(script.javascript, component.typeArguments);
  const { ast: emptyAst } = parse("<script/>");
  const empty = view(emptyAst, emptyAst.template.nodes[0].javascript);
  assert.deepEqual(entries(empty, payload(empty, empty.root, "program").body), [] as any[]);
});
test("independent programs retain nested markup, comments and local return rules", () => {
  const source =
    '---\n/*front*/ const label: string = "front";\n' +
    "function markup() { return <article><script>/*inner*/ const inside = 1;</script>" +
    "{label}</article>; }\n---\n" +
    "<script>/*outer*/ const outside: number = 2;</script>{label}";
  const { ast, diagnostics } = parse(source);
  assert.deepEqual(diagnostics, [] as any[]);
  const scripts = ast.template.nodes.filter((node) => node.typeName === "Script");
  assert.strictEqual(scripts.length, 2);
  const roots = [ast.frontmatter!.root, ...scripts.map((node) => node.javascript)];
  assert.strictEqual(new Set(roots).size, 3);
  for (const root of roots) assert.ok(ast.tree.nodes[root!].data.program);
  assert.deepEqual(
    ast.tree.comments.map((comment) => stringBytes(ast.tree, comment.value).toString()),
    ["front", "inner", "outer"],
  );
  assert.strictEqual(ast.tree.tokens.filter((token) => token.tag === "eof").length, 1);
  const invalid = "---\nreturn 1;\n---\n<script>return 2;</script>";
  const scriptStart = Buffer.byteLength(invalid.slice(0, invalid.indexOf("return 2")));
  assert.ok(
    parse(invalid).diagnostics.some(
      (diagnostic) => diagnostic.severity === "error" && diagnostic.start === scriptStart,
    ),
  );
});
test("Unicode spans stay in original UTF-8 bytes and Yuku diagnostic messages survive", () => {
  const source = "<p>日本😀{名 + }</p>";
  const { ast, diagnostics } = parse(source);
  assert.ok(diagnostics.length > 0);
  assert.strictEqual(ast.end, Buffer.byteLength(source));
  const expression = ast.template.nodes.find((node) => node.typeName === "Expression");
  assert.ok(expression);
  assert.strictEqual(expression.start, Buffer.byteLength("<p>日本😀"));
  const tree = view(ast, expression.javascript);
  assert.strictEqual(tree.root, NULL);
  assert.ok(tree.diagnostics.length > 0);
  for (const diagnostic of tree.diagnostics) {
    const outward = diagnostics.find(
      (item) => item.message === diagnostic.message && item.start === diagnostic.span.start,
    );
    assert.ok(outward);
    assert.strictEqual(outward.end, diagnostic.span.end);
    assert.strictEqual(outward.severity, diagnostic.severity);
    assert.deepEqual(outward.labels, diagnostic.labels);
  }
});
test("nested markup and many sibling expressions keep one valid global ID namespace", () => {
  const source =
    "---\nconst view = () => <Card value={base + 1}>{item + 2}</Card>;\n---\n" +
    "{items.map(x => <li value={x.id}>{x.name}</li>)}" +
    Array.from({ length: 300 }, (_, i) => `{value + ${i}}`).join("") +
    "<script>const end = 1;</script><Generic<Map<string, number>>/>";
  const { ast, diagnostics } = parse(source);
  assert.deepEqual(diagnostics, [] as any[]);
  const tree = ast.tree;
  const body = entries(tree, payload(tree, tree.root, "program").body);
  assert.strictEqual(body.length, 1);
  assert.strictEqual(payload(tree, body[0], "dialect").kind, "document");
  const references = [
    ast.frontmatter!.root,
    ...ast.template.nodes.flatMap((node) =>
      [node.javascript, node.typeArguments].filter((id) => id !== null && id !== NULL),
    ),
  ];
  assert.strictEqual(new Set(references).size, references.length);
  for (const id of references) assert.ok(tree.nodes[id!]);
  for (const id of tree.extras) assert.ok(id === NULL || tree.nodes[id!]);
  assert.strictEqual(tree.markup.length, 6);
  for (const link of tree.markup) {
    const native = ast.template.nodes[link.astro_node];
    assert.deepEqual(tree.nodes[link.node].span, { start: native.start, end: native.end });
    for (const child of native.children) {
      const root = ast.template.nodes[child].javascript;
      if (root !== null) assert.ok(tree.nodes[root!]);
    }
  }
});
