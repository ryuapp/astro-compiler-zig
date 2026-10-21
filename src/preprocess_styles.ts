import type { Binding } from "./binding.ts";
import type { PreprocessedStyles, PreprocessorError, PreprocessorResult } from "./types.ts";

type Result = PreprocessorResult | PreprocessorError | null;
type SyncPreprocessor = (content: string, attrs: Record<string, string>) => Result;
type AsyncPreprocessor = (content: string, attrs: Record<string, string>) => Promise<Result>;
type Preprocessor = SyncPreprocessor | AsyncPreprocessor;

function isPromise(result: Result | Promise<Result>): result is Promise<Result> {
  return result != null && typeof (result as Promise<Result>).then === "function";
}

function failure(error: unknown): PreprocessorError {
  return { error: error instanceof Error ? error.message : String(error) };
}

// Match the reference binding's StringExpected errors on the public API, including
// JSON serialization errors raised while describing non-string input values.
function checkSource(source: unknown): asserts source is string {
  if (typeof source === "string") return;
  let description: string;
  switch (typeof source) {
    case "undefined":
      description = "Undefined";
      break;
    case "boolean":
      description = `Boolean ${source} `;
      break;
    case "number":
      description = `Number ${source} `;
      break;
    case "symbol":
      description = "Symbol";
      break;
    case "function": {
      const name: unknown = source.name;
      checkSource(name);
      description = `function ${name || "anonymous"}(..) `;
      break;
    }
    case "object": {
      const serialized = source === null ? null : JSON.stringify(source);
      description =
        source === null ? "Null" : serialized === undefined ? "Undefined" : `Object ${serialized}`;
      break;
    }
    default:
      description = "Unknown";
  }
  throw Object.assign(
    new Error(`Failed to convert JavaScript value \`${description}\` into rust type \`String\``),
    { code: "StringExpected" },
  );
}

// Callback and error semantics follow Astro Compiler (MIT); terms are in LICENSE.
// https://github.com/withastro/compiler-rs/blob/main/packages/compiler/src/shared.ts
function collect(results: Result[]): PreprocessedStyles {
  const styleError: string[] = [];
  const styles = results.map((result) => {
    if (result == null) return undefined;
    if ("error" in result && typeof result.error === "string") {
      styleError.push(result.error);
      return "";
    }
    return (result as PreprocessorResult).code;
  });
  return { styles, styleError };
}

export default function createStylePreprocessor(binding: Pick<Binding, "extractStyles">) {
  function preprocessStyles(source: string, preprocessStyle: SyncPreprocessor): PreprocessedStyles;
  function preprocessStyles(
    source: string,
    preprocessStyle: AsyncPreprocessor,
  ): Promise<PreprocessedStyles>;
  function preprocessStyles(
    source: string,
    preprocessStyle: Preprocessor,
  ): PreprocessedStyles | Promise<PreprocessedStyles> {
    checkSource(source);
    const results: (Result | Promise<Result>)[] = [];
    let asynchronous = false;
    for (const block of binding.extractStyles(source)) {
      const attrs: Record<string, string> = {};
      for (const attr of block.attrs) attrs[attr.name] = attr.value;
      try {
        // The published 0.5.2 wrapper names its callback `n`; its message is part
        // of styleError when a non-callable callback is supplied.
        if (typeof preprocessStyle !== "function") throw new TypeError("n is not a function");
        const result = preprocessStyle(block.content, attrs);
        asynchronous = isPromise(result) || asynchronous;
        results.push(result);
      } catch (error) {
        results.push(failure(error));
      }
    }
    if (!asynchronous) return collect(results as Result[]);
    return Promise.all(
      results.map(async (result) => {
        try {
          return await result;
        } catch (error) {
          return failure(error);
        }
      }),
    ).then(collect);
  }
  return preprocessStyles;
}
