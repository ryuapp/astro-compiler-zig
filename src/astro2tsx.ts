import type { Binding } from "./binding.ts";
import type { ConvertToTsxOptions } from "./types.ts";

export default (binding: Binding) =>
  function convertToTsx(source: string, options: ConvertToTsxOptions | null = {}) {
    if (typeof source !== "string") throw new TypeError("Expected an Astro source string");
    options ??= {};
    if (typeof options !== "object" || Array.isArray(options))
      throw new TypeError("Expected conversion options");
    if (options.filename !== undefined && typeof options.filename !== "string")
      throw new TypeError("Expected a filename string");
    if (options.ambientTypes !== undefined && typeof options.ambientTypes !== "boolean")
      throw new TypeError("Expected ambientTypes boolean");
    return binding.convertToTsx(source, options);
  };
