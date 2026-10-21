import { replaceComponentPaths } from "./transform_paths.ts";
import { decodeUtf8, encodeUtf8, encodeBase64 } from "./encoding.ts";

export default (binding: any) =>
  function transform(source: string, options: any) {
    if (typeof source !== "string") throw new TypeError("Expected an Astro source string");
    if (options != null && (typeof options !== "object" || Array.isArray(options)))
      throw new TypeError("Expected transform options");
    options ??= {};
    const encoded: Record<string, any> = {};
    for (const key of [
      "filename",
      "normalizedFilename",
      "internalURL",
      "sourcemap",
      "astroGlobalArgs",
      "compact",
      "scopedStyleStrategy",
      "resultScopedSlot",
      "transitionsAnimationURL",
      "annotateSourceFile",
      "inlineComponentAssets",
    ]) {
      let value = options[key];
      if (value === undefined || value === null) continue;
      if (key === "compact") value = value === true ? "html" : value === "jsx" ? "jsx" : "none";
      const nativeKey = key.replace(
        /[A-Z]+(?=[A-Z][a-z]|$)|[A-Z]/g,
        (part) => "_" + part.toLowerCase(),
      );
      encoded[nativeKey] = value;
    }
    encoded.resolve_path_provided = typeof options.resolvePath === "function";
    if (options.preprocessedStyles?.styles.some((style: any) => style != null))
      encoded.preprocessed_styles = options.preprocessedStyles.styles;
    const result = binding.transform(source, JSON.stringify(encoded));
    if ("sourcemap" in encoded && result.code) {
      const filename = encoded.filename ?? "<stdin>";
      const map = JSON.stringify({
        version: 3,
        file: filename,
        sources: [filename],
        sourcesContent: [source.toWellFormed()],
        names: [],
        mappings: result.map,
      });
      const mode = encoded.sourcemap;
      if (mode === "inline" || mode === "both")
        result.code += "\n//# sourceMappingURL=data:application/json;base64," + encodeBase64(map);
      result.map = mode === "inline" ? "" : map;
    }
    for (const script of result.scripts) {
      if (script.code == null) delete script.code;
      if (script.src == null) delete script.src;
    }
    let bytes;
    function location(offset: number) {
      bytes ??= encodeUtf8(source);
      const prefix = decodeUtf8(bytes.subarray(0, offset));
      const lines = prefix.split(/\r\n|\r|\n/);
      return { line: lines.length, column: Array.from(lines.at(-1)!).length };
    }
    result.diagnostics = result.diagnostics.map((diagnostic: any) => ({
      severity: diagnostic.severity,
      text: diagnostic.message,
      hint: diagnostic.help ?? "",
      labels: (diagnostic.labels.length
        ? diagnostic.labels.map((label: any) => ({
            text: label.message || null,
            start: label.span.start,
            end: label.span.end,
          }))
        : diagnostic.start == null
          ? ([] as any[])
          : [
              {
                text: null,
                start: diagnostic.start,
                end: diagnostic.end ?? diagnostic.start,
              },
            ]
      ).map((label: any) => ({ ...label, ...location(label.start) })),
    }));
    if (options.preprocessedStyles?.styleError?.length)
      result.styleError = options.preprocessedStyles.styleError;
    if (encoded.resolve_path_provided) {
      const replacements = new Map<string, string>();
      for (const component of [
        ...result.hydratedComponents,
        ...result.clientOnlyComponents,
        ...result.serverComponents,
      ]) {
        const previous = component.resolvedPath;
        component.resolvedPath = options.resolvePath(component.specifier);
        if (component.resolvedPath && component.resolvedPath !== component.specifier) {
          const key = '"client:component-path": ' + JSON.stringify(previous);
          if (!replacements.has(key))
            replacements.set(
              key,
              '"client:component-path": ' +
                JSON.stringify(component.resolvedPath)
                  .replaceAll("\u2028", "\\u2028")
                  .replaceAll("\u2029", "\\u2029"),
            );
        }
      }
      replaceComponentPaths(result, replacements);
    }
    return result;
  };
