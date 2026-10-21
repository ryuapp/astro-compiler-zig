import createParser from "./parse.ts";
import createTsxConverter from "./astro2tsx.ts";
import createTransformer from "./transform.ts";
import createStylePreprocessor from "./preprocess_styles.ts";
import { createWasmBinding } from "./wasm.ts";
import type {
  ParseResult,
  ConvertToTsxOptions,
  ConvertToTsxResult,
  TransformOptions,
  TransformResult,
} from "./types.ts";

export {
  AstroFrontmatterStatus,
  DiagnosticSeverity,
  ExtractedScriptType,
  ExtractedStyleType,
} from "./types.ts";
export type {
  ESTreeNode,
  ParseResult,
  AstroParseResult,
  PreprocessorResult,
  PreprocessorError,
  PreprocessedStyles,
  TransformOptions,
  Component,
  HoistedScript,
  DiagnosticLabel,
  DiagnosticMessage,
  TransformResult,
  Range,
  ConvertToTsxOptions,
  AstroDiagnostic,
  ExtractedScript,
  ExtractedStyle,
  TsxMapping,
  ConvertToTsxResult,
} from "./types.ts";

// The pack banner supplies the source-phase import, which TypeScript cannot parse.
declare const wasm: WebAssembly.Module;
const binding = createWasmBinding(wasm);
export const parse: (source: string) => ParseResult = createParser(binding).parse;
export const convertToTsx: (
  source: string,
  options?: ConvertToTsxOptions | null,
) => ConvertToTsxResult = createTsxConverter(binding);
export const transform: (source: string, options?: TransformOptions) => TransformResult =
  createTransformer(binding);
export const preprocessStyles = createStylePreprocessor(binding);
