const decoder = new TextDecoder("utf-8", { ignoreBOM: true });

export function encodeUtf8(value: string): Uint8Array<ArrayBuffer> {
  return Buffer.from(value);
}

export function decodeUtf8(bytes: Uint8Array<ArrayBuffer>): string {
  return decoder.decode(bytes);
}

export function utf8Length(value: string): number {
  return Buffer.byteLength(value);
}

export function writeSource(
  memory: ArrayBuffer,
  offset: number,
  length: number,
  value: string,
  encoding: "utf8" | "utf16le",
): void {
  Buffer.from(memory, offset, length).write(value, 0, length, encoding);
}

export function decodeUtf16(bytes: Uint8Array<ArrayBuffer>): string {
  return Buffer.from(bytes.buffer, bytes.byteOffset, bytes.length).toString("utf16le");
}

export function encodeBase64(value: string): string {
  return Buffer.from(value).toString("base64");
}

export function decodeBase64(value: string): Uint8Array<ArrayBuffer> {
  return Buffer.from(value, "base64");
}
