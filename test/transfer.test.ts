import { assert, test } from "vite-plus/test";
import { binding } from "./parse-internal.ts";
import { parse } from "./parse-internal.ts";
import { decodeSnapshot as decode, Reader } from "../src/transfer_decode.ts";

test("owned transfer buffers survive subsequent parses and reject invalid input", () => {
  const source = '---\nconst value="\\uDFFF";\n---\n<p>{value}</p>';
  const expected = structuredClone(parse(source));
  const buffer = binding.parseBuffer(source);
  for (let index = 0; index < 50; index++) parse(`{${index}+1}`);
  assert.deepEqual(decode(buffer, source, true), expected);
  const invalid = buffer.slice(0);
  new DataView(invalid).setUint32(4, 0xffffffff, true);
  assert.throws(() => decode(invalid, source, true), /Unsupported Astro transfer format/);
  assert.throws(() => decode(buffer.slice(0, 12), source, true), RangeError);
  assert.throws(() => decode(buffer, source + " ", true), /source length mismatch/);
});

test("transfer source slices share a position table for only the non-ASCII suffix", () => {
  for (const length of [0, 15, 16, 17, 65_536]) {
    const prefix = "a".repeat(length);
    for (const value of ["", "ascii", "é", "日本語", "🦀", "e\u0301", "\ud800", "\udc00"]) {
      const source = prefix + value + "\r\nend";
      const reader = new Reader(binding.parseBuffer(source), source);
      reader.open(true);
      assert.strictEqual(reader.slice(0, length), prefix);
      assert.strictEqual(reader.offsets, null);
      const valueEnd = length + Buffer.byteLength(value);
      assert.strictEqual(reader.slice(length, valueEnd), value.toWellFormed());
      const offsets = reader.offsets as Uint32Array | null;
      assert.strictEqual(reader.slice(0, Buffer.byteLength(source)), source.toWellFormed());
      assert.strictEqual(reader.slice(valueEnd, Buffer.byteLength(source)), "\r\nend");
      assert.strictEqual(reader.offsets, offsets);
      const firstNonAscii = source.search(/\P{ASCII}/u);
      assert.strictEqual(
        offsets?.byteLength ?? 0,
        firstNonAscii < 0 ? 0 : (Buffer.byteLength(source) - firstNonAscii + 1) * 4,
      );
    }
  }
});
