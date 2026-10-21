import { readFileSync } from "node:fs";
import { createWasmBinding } from "../src/wasm.ts";
import { decodeSnapshot as decode } from "../src/transfer_decode.ts";

export const binding = createWasmBinding(
  new WebAssembly.Module(readFileSync(new URL("../dist/compiler.wasm", import.meta.url))),
);
export const parse = (source: string) => decode(binding.parseBuffer(source), source, true);
