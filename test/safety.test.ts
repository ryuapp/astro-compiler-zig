import { createRequire as createModuleRequire } from "node:module";
import { spawnSync } from "node:child_process";
import path from "node:path";
import { assert, test as module3 } from "vite-plus/test";
import module4 from "node:worker_threads";
const require = createModuleRequire(import.meta.url);
const test = module3;
// Isolate adversarial parser inputs so any process failure has a clear fixture.
function isolatedParse(source: string) {
  const program =
    'const {parse}=require("./dist/index.mjs");' +
    'const source=require("node:fs").readFileSync(0,"utf8");' +
    "const result=parse(source);" +
    'if(result.ast.type!=="AstroRoot")process.exit(2);' +
    'const end=result.ast.frontmatter.end;const template=source.slice(end).replace(/^\\r?\\n/, "");' +
    "const frontmatterNodes=[],pending=[result.ast.frontmatter.program];while(pending.length){" +
    "const item=pending.pop();if(Array.isArray(item))pending.push(...item);else if(item&&typeof item==='object'){" +
    "if(typeof item.start==='number')frontmatterNodes.push({start:item.start,end:item.end});pending.push(...Object.values(item));}}" +
    "process.stdout.write(JSON.stringify({diagnostics:result.diagnostics,template,frontmatterEnd:end,frontmatterNodes}));";
  const result = spawnSync(process.execPath, ["-e", program], {
    cwd: path.resolve(import.meta.dirname, ".."),
    input: source,
    encoding: "utf8",
    timeout: 10000,
    maxBuffer: 8 * 1024 * 1024,
  });
  assert.ifError(result.error);
  assert.strictEqual(result.status, 0, result.stderr);
  return JSON.parse(result.stdout);
}
test("excessive Astro nesting and invalid template expressions return diagnostics safely", () => {
  for (const source of [
    "<X a={".repeat(1024) + "0" + "}/>".repeat(1024),
    "<div>".repeat(1024) + "x" + "</div>".repeat(1024),
    "---\nconst value = `" + "${".repeat(1024) + "0" + "}".repeat(1024) + "`;\n---\n<p/>",
  ]) {
    assert.ok(isolatedParse(source).diagnostics.length > 0, source.slice(0, 100));
  }
});
test("malformed frontmatter markup never reads beyond its Yuku program range", () => {
  for (const [source, template, diagnosticRequired] of [
    ["---\nconst node = <Card\n---\n<p>body</p>", "<p>body</p>", true],
    ["---\nconst node = <div>{name}\n---\n<style>p{}</style>", "<style>p{}</style>", false],
  ] as [string, string, boolean][]) {
    const result = isolatedParse(source);
    if (diagnosticRequired) assert.ok(result.diagnostics.length > 0, source);
    assert.strictEqual(result.template, template);
    for (const node of result.frontmatterNodes) assert.ok(node.end <= result.frontmatterEnd);
  }
});
test("marker selection has bounded work for long user prefix spellings", () => {
  const source = "_".repeat(20000) + "astro_native_";
  const result = isolatedParse(source);
  assert.deepEqual(result.diagnostics, [] as any[]);
  assert.strictEqual(result.template, source);
});
test("worker threads keep their WASM instances independent", async () => {
  const { Worker } = module4;
  const entry = require.resolve("../dist/index.mjs");
  await Promise.all(
    Array.from(
      { length: 4 },
      () =>
        new Promise<void>((resolve, reject) => {
          const worker = new Worker(
            'const {parentPort,workerData}=require("node:worker_threads");' +
              "const {parse,transform,convertToTsx}=require(workerData);" +
              'for(let i=0;i<50;i++){if(parse("<p>{1}</p>").diagnostics.length)throw Error("parse failed");transform("<p>{1}</p>");' +
              'if(!convertToTsx("<p>{1}</p>").code.includes("<p>{1}</p>"))throw Error("TSX failed");}' +
              'parentPort.postMessage("ok");',
            { eval: true, workerData: entry },
          );
          let received = false;
          worker.on("message", (message) => {
            received = message === "ok";
          });
          worker.on("error", reject);
          worker.on("exit", (code) => {
            if (code === 0 && received) resolve();
            else reject(new Error(`Worker failed with exit ${code}`));
          });
        }),
    ),
  );
});
test("WASM instances support forced Worker termination", async () => {
  const entry = require.resolve("../dist/index.mjs");
  await Promise.all(
    Array.from({ length: 4 }, async () => {
      const worker = new module4.Worker(
        'const {parentPort,workerData}=require("node:worker_threads");' +
          "const {parse}=require(workerData);" +
          'const source="<div>"+"<p>{1 + 2}</p>".repeat(2000)+"</div>";' +
          'parse(source);parentPort.postMessage("ready");while(true)parse(source);',
        { eval: true, workerData: entry },
      );
      await new Promise<void>((resolve, reject) => {
        worker.once("message", () => resolve());
        worker.once("error", reject);
        worker.once("exit", (code) => reject(new Error(`Worker exited before readiness: ${code}`)));
      });
      assert.strictEqual(await worker.terminate(), 1);
    }),
  );
});

test("ESTree restoration retains long valid chains in a Node process", () => {
  const program =
    'import("vite-plus/test").then(({assert})=>{const {parse}=require("./dist/index.mjs");' +
    'const count=2000;let source="{obj"+".x".repeat(count)+"}";' +
    "let result=parse(source);assert.deepEqual(result.diagnostics,[]);" +
    "let node=result.ast.body[0].expression;for(let i=count;i>0;i--){" +
    'assert.strictEqual(node.type,"MemberExpression");node=node.object;}' +
    'assert.strictEqual(node.type,"Identifier");' +
    'source="{0"+"+1".repeat(5000)+"}";result=parse(source);assert.deepEqual(result.diagnostics,[]);' +
    "node=result.ast.body[0].expression;for(let i=0;i<5000;i++){" +
    'assert.strictEqual(node.type,"BinaryExpression");assert.strictEqual(node.operator,"+");node=node.left;}' +
    'assert.strictEqual(node.type,"Literal");});';
  const result = spawnSync(process.execPath, ["-e", program], {
    cwd: path.resolve(import.meta.dirname, ".."),
    encoding: "utf8",
    timeout: 10000,
  });
  assert.ifError(result.error);
  assert.strictEqual(result.status, 0, result.stderr);
});
test("deep valid JavaScript and TypeScript retain complete ASTs without an artificial limit", () => {
  const program =
    'import("vite-plus/test").then(({assert})=>{const {parse}=require("./dist/index.mjs");' +
    'const source=require("node:fs").readFileSync(0,"utf8");const result=parse(source);' +
    'assert.strictEqual(result.ast.type,"AstroRoot");assert.deepEqual(result.diagnostics,[]);';
  for (const [source, check] of [
    [
      "{" + "[".repeat(2048) + "0" + "]".repeat(2048) + "}",
      'let n=result.ast.body[0].expression;for(let i=0;i<2048;i++){assert.strictEqual(n.type,"ArrayExpression");assert.strictEqual(n.elements.length,1);n=n.elements[0];}assert.strictEqual(n.value,0);',
    ],
    [
      "<X<" + "Foo<".repeat(1000) + "string" + ">".repeat(1000) + ">/>",
      'let n=result.ast.body[0].openingElement.typeArguments.params[0];for(let i=0;i<1000;i++){assert.strictEqual(n.type,"TSTypeReference");assert.strictEqual(n.typeName.name,"Foo");n=n.typeArguments.params[0];}assert.strictEqual(n.type,"TSStringKeyword");',
    ],
    [
      "---\ntype X = " + "keyof ".repeat(1000) + "Y;\n---\n<p/>",
      'let n=result.ast.frontmatter.program.body[0].typeAnnotation;for(let i=0;i<1000;i++){assert.strictEqual(n.type,"TSTypeOperator");assert.strictEqual(n.operator,"keyof");n=n.typeAnnotation;}assert.strictEqual(n.typeName.name,"Y");',
    ],
  ]) {
    const result = spawnSync(process.execPath, ["-e", program + check + "});"], {
      cwd: path.resolve(import.meta.dirname, ".."),
      input: source,
      encoding: "utf8",
      timeout: 10000,
    });
    assert.ifError(result.error);
    assert.strictEqual(result.status, 0, result.stderr);
  }
});
test("nested programs retain independent valid JavaScript nesting in the shared tree", () => {
  const array = "[".repeat(80) + "0" + "]".repeat(80);
  const expression =
    "[".repeat(80) + "<script>const value = " + array + ";</script>" + "]".repeat(80);
  const source = "---\nconst value = " + expression + ";\n---\n";
  const program =
    'const {parse}=require("./dist/index.mjs");' +
    'import("vite-plus/test").then(({assert})=>{' +
    'const array="[".repeat(80)+"0"+"]".repeat(80);' +
    'assert.deepEqual(parse("<script>const value="+array+";</script>").diagnostics,[]);' +
    'const source=require("node:fs").readFileSync(0,"utf8");' +
    "const result=parse(source);assert.deepEqual(result.diagnostics,[]);" +
    "let node=result.ast.frontmatter.program.body[0].declarations[0].init;" +
    'for(let i=0;i<80;i++){assert.strictEqual(node.type,"ArrayExpression");node=node.elements[0];}' +
    'assert.strictEqual(node.openingElement.name.name,"script");node=node.children[0].program.body[0].declarations[0].init;' +
    'for(let i=0;i<80;i++){assert.strictEqual(node.type,"ArrayExpression");node=node.elements[0];}assert.strictEqual(node.value,0);});';
  const result = spawnSync(process.execPath, ["-e", program], {
    cwd: path.resolve(import.meta.dirname, ".."),
    input: source,
    encoding: "utf8",
    timeout: 10000,
  });
  assert.ifError(result.error);
  assert.strictEqual(result.status, 0, result.stderr);
});
