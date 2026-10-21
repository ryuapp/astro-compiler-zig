import decode, { Reader } from "./transfer_decode.ts";
import estree from "./estree.ts";
import type { Binding } from "./binding.ts";
export default (binding: Binding) => ({
  parse: (source: string) => {
    const reader = new Reader(binding.parseBuffer(source), source);
    return estree(reader, binding.littleEndian);
  },
  parseForTsx: (source: string) =>
    decode(new Reader(binding.parseForTsxBuffer(source), source), binding.littleEndian),
});
