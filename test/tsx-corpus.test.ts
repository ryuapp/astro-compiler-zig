import { convertToTsx } from "../dist/index.mjs";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { test } from "vite-plus/test";
import { assertTsxCompatibility } from "./tsx-compat.ts";
import { convertToTsx as reference } from "@astrojs/astro2tsx";
function files(folder: string): string[] {
  return readdirSync(folder, { withFileTypes: true }).flatMap((entry) => {
    const file = join(folder, entry.name);
    return entry.isDirectory() ? files(file) : file.endsWith(".astro") ? [file] : ([] as any[]);
  });
}
const inputs = [
  "test/fixtures/tsx-upstream/fixtures",
  "test/fixtures/transform-upstream/fixtures",
].flatMap((folder) =>
  files(folder).map((file) => ({ name: file, source: readFileSync(file, "utf8") })),
);
for (const fixture of inputs)
  test("TSX corpus: " + fixture.name, () => {
    let { source } = fixture;
    const options: import("../src/types.ts").ConvertToTsxOptions = {};
    while (source.startsWith("// @config ")) {
      const newline = source.indexOf("\n");
      const line = source.slice(0, newline < 0 ? source.length : newline).trim();
      if (line.startsWith("// @config filename="))
        options.filename = line.slice("// @config filename=".length);
      source = newline < 0 ? "" : source.slice(newline + 1);
    }
    const expected = reference(source, options),
      actual = convertToTsx(source, options);
    assertTsxCompatibility(
      source,
      actual,
      expected,
      fixture.name.endsWith("props_generic_invalid.astro"),
    );
  });
