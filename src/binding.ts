import type { ConvertToTsxOptions, ConvertToTsxResult } from "./types.ts";

export interface StyleBlock {
  index: number;
  content: string;
  attrs: { name: string; value: string }[];
}

export interface Binding {
  littleEndian?: boolean;
  parseBuffer(source: string): ArrayBuffer;
  parseForTsxBuffer(source: string): ArrayBuffer;
  extractStyles(source: string): StyleBlock[];
  convertToTsx(
    this: void,
    source: string,
    options?: ConvertToTsxOptions | null,
  ): ConvertToTsxResult;
  [name: string]: any;
}
