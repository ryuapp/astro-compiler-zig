// Test-only adapter for upstream's separate async entry point. Production exports
// are synchronous; every final code and map assertion still uses public transform.
import { transform as transformSync } from "../../dist/index.mjs";
import type { TransformOptions } from "../../src/types.ts";

type AsyncOptions = Omit<TransformOptions, "resolvePath"> & {
  resolvePath?: (specifier: string) => string | Promise<string>;
};

export async function transform(source: string, options?: AsyncOptions) {
  const resolvePath = options?.resolvePath;
  if (!resolvePath) return transformSync(source, options as TransformOptions);
  const pending = new Map<string, Promise<string>>();
  transformSync(source, {
    ...options,
    resolvePath(specifier) {
      if (!pending.has(specifier)) pending.set(specifier, Promise.resolve(resolvePath(specifier)));
      return specifier;
    },
  });
  const resolved = new Map(
    await Promise.all(
      [...pending].map(async ([specifier, value]) => [specifier, await value] as const),
    ),
  );
  return transformSync(source, {
    ...options,
    resolvePath: (specifier) => resolved.get(specifier) ?? specifier,
  });
}
