import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import { assert, test } from "vite-plus/test";
import ts from "typescript-compat";
import { Reader, decodeSnapshot } from "../src/transfer_decode.ts";
import { binding } from "./parse-internal.ts";
import { byteIndex } from "../src/positions.ts";
import { createDecoder } from "../src/estree_nodes.ts";

function bigEndianWords(buffer: ArrayBuffer, offset: number, count: number) {
  const view = new DataView(buffer, offset, count * 4);
  return new Proxy(
    {},
    {
      get: (_, key) => view.getInt32(Number(key) * 4, false),
      set: (_, key, value: number) => {
        view.setInt32(Number(key) * 4, value, false);
        return true;
      },
    },
  );
}

test("WASM records restore complete ASTs with simulated big endian host word reads", () => {
  const module: { createDecoder?: typeof import("../src/estree_nodes.ts").createDecoder } = {};
  const code = ts.transpileModule(
    readFileSync(new URL("../src/estree_nodes.ts", import.meta.url), "utf8"),
    { compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 } },
  ).outputText;
  runInNewContext(code, {
    exports: module,
    TextDecoder,
    Uint8Array,
    Uint16Array: class {
      buffer = Uint8Array.of(0, 1).buffer;
    },
    Int32Array: bigEndianWords,
  });
  assert.ok(module.createDecoder);
  for (const source of [
    "---\nconst values=[1,2];export function f(value:number=1){return values[value];}\n---",
    '---\r\n/*🦊*/const 名前="é";export const object={名前};\r\n---',
    "---\ninterface Props<T>{value:T}const fn=<T,>(value:T)=>value;\n---",
  ]) {
    const buffer = binding.parseBuffer(source);
    const header = new Reader(buffer, source).open(true);
    const root = decodeSnapshot(buffer, source, true).ast.frontmatter!.root;
    const offsets = header[9] < header[3] ? byteIndex(source, header[3], header[9]) : null;
    const markup = () => {
      throw new Error("Unexpected Astro markup in the JavaScript fixture");
    };
    const expected = createDecoder(buffer.slice(0), source, new Map(), markup, offsets)(root);
    assert.strictEqual(expected.type, "Program");
    assert.ok(expected.body.length > 0);
    const decode = module.createDecoder(buffer, source, new Map(), markup, offsets);
    assert.deepEqual(JSON.parse(JSON.stringify(decode(root))), expected, source);
    assert.strictEqual(new DataView(buffer).getUint32(24, false), Buffer.byteLength(source));
  }
});
