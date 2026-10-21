import { decodeUtf8, decodeUtf16, utf8Length, writeSource } from "./encoding.ts";
import type { Binding } from "./binding.ts";
import type { ConvertToTsxOptions, ConvertToTsxResult } from "./types.ts";

interface WasmExports extends WebAssembly.Exports {
  memory: WebAssembly.Memory;
  prepare(length: number): number;
  parse(length: number, editor: number): number;
  convert_to_tsx(
    length: number,
    filenameLength: number,
    hasFilename: number,
    ambient: number,
  ): number;
  transform(length: number, optionsLength: number): number;
  extract_styles(length: number): number;
  result_size(): number;
  error_pointer(): number;
  error_length(): number;
  release(): void;
}

function readValue(buffer: Uint8Array<ArrayBuffer>): any {
  const view = new DataView(buffer.buffer, buffer.byteOffset, buffer.length);
  let offset = 0;
  function integer() {
    const value = view.getUint32(offset, true);
    offset += 4;
    return value;
  }
  function string() {
    const size = integer();
    const value = decodeUtf16(buffer.subarray(offset, offset + size));
    offset += size;
    return value;
  }
  function value(): any {
    switch (buffer[offset++]) {
      case 0:
        return null;
      case 1:
        return false;
      case 2:
        return true;
      case 3: {
        const number = view.getFloat64(offset, true);
        offset += 8;
        return number;
      }
      case 4:
        return string();
      case 5:
        return Array.from({ length: integer() }, value);
      case 6: {
        const result: Record<string, any> = {};
        for (let count = integer(); count > 0; count--) {
          const key = string().replace(/_([a-z])/g, (_, character: string) =>
            character.toUpperCase(),
          );
          result[key] = value();
        }
        return result;
      }
      default:
        throw new Error("Invalid WASM result");
    }
  }
  return value();
}

export function createWasmBinding(module: WebAssembly.Module): Binding {
  const instance = new WebAssembly.Instance(module);
  const raw = instance.exports as WasmExports;
  function checked(pointer: number) {
    if (!pointer) {
      const start = raw.error_pointer() >>> 0;
      const message = decodeUtf8(
        new Uint8Array(raw.memory.buffer, start, raw.error_length() >>> 0),
      );
      throw new Error(message || "WASM operation failed");
    }
    return pointer >>> 0;
  }
  function invoke(
    source: string,
    encoding: "utf8" | "utf16le",
    extra: string,
    operation: (length: number, extraLength: number) => number,
    binary = false,
  ): any {
    if (typeof source !== "string") throw new TypeError("Expected an Astro source string");
    const length = encoding === "utf16le" ? source.length * 2 : utf8Length(source);
    const extraLength = utf8Length(extra);
    if (length + extraLength >= 0xffffffff) throw new Error("SourceTooLarge");
    try {
      const input = checked(raw.prepare(length + extraLength));
      writeSource(raw.memory.buffer, input, length, source, encoding);
      writeSource(raw.memory.buffer, input + length, extraLength, extra, "utf8");
      const output = checked(operation(length, extraLength));
      const size = raw.result_size() >>> 0;
      // Parsing may grow linear memory. Refresh the view after the operation.
      if (binary) return raw.memory.buffer.slice(output, output + size);
      return readValue(new Uint8Array(raw.memory.buffer, output, size));
    } finally {
      raw.release();
    }
  }
  return {
    littleEndian: true,
    parseBuffer: (source) => invoke(source, "utf8", "", (length) => raw.parse(length, 0), true),
    parseForTsxBuffer: (source) =>
      invoke(source, "utf8", "", (length) => raw.parse(length, 1), true),
    extractStyles: (source) => invoke(source, "utf8", "", (length) => raw.extract_styles(length)),
    convertToTsx(source: string, options?: ConvertToTsxOptions | null): ConvertToTsxResult {
      options ??= {};
      if (typeof options !== "object" || Array.isArray(options))
        throw new TypeError("Expected conversion options");
      const filename = options.filename;
      const ambientTypes = options.ambientTypes;
      if (filename !== undefined && typeof filename !== "string")
        throw new TypeError("Expected a filename string");
      if (ambientTypes !== undefined && typeof ambientTypes !== "boolean")
        throw new TypeError("Expected ambientTypes boolean");
      const result = invoke(source, "utf16le", filename ?? "", (length, filenameLength) =>
        raw.convert_to_tsx(
          length,
          filenameLength,
          filename === undefined ? 0 : 1,
          ambientTypes ? 1 : 0,
        ),
      );
      delete result.generatedScriptRanges;
      delete result.generatedStyleRanges;
      if (result.generatedComponentExport === null) delete result.generatedComponentExport;
      return result;
    },
    transform: (source: string, options = "{}") =>
      invoke(source, "utf8", options, (length, extraLength) => raw.transform(length, extraLength)),
  };
}
