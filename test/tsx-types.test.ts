import { createRequire as createModuleRequire } from "node:module";
import { resolve } from "node:path";
import { assert, test } from "vite-plus/test";
import { convertToTsx } from "../dist/index.mjs";
const require = createModuleRequire(import.meta.url);
const ts = require("typescript-compat");
const filename = resolve("test/tsx-types/consumer.tsx").replaceAll("\\", "/");
const ambient = filename.replace("consumer.tsx", "ambient.d.ts");
const declarations = `declare module 'astro' {
    export type AstroGlobal<P, C, Params = unknown> = {props: P; params: Params};
}
declare module 'astro/jsx-runtime' {
    export namespace JSX { interface IntrinsicElements { [name: string]: any } }
}`;
function check(name: string, frontmatter: string, expected: number[]) {
  test(name, () => {
    const source = `---\n${frontmatter}\n---`,
      result = convertToTsx(source, { ambientTypes: true });
    assert.strictEqual(result.hasParseErrors, false, JSON.stringify(result.diagnostics));
    const files = new Map([
      [filename, result.code],
      [ambient, declarations],
    ]);
    const options = {
      noEmit: true,
      strict: true,
      isolatedModules: true,
      target: ts.ScriptTarget.ESNext,
      module: ts.ModuleKind.ESNext,
      moduleResolution: ts.ModuleResolutionKind.Bundler,
      jsx: ts.JsxEmit.Preserve,
      types: [] as any[],
    };
    const host = ts.createCompilerHost(options),
      get = host.getSourceFile,
      exists = host.fileExists;
    // These fixtures supply their own Astro declarations, independent of the installed runtime.
    host.resolveModuleNames = (names: string[], containingFile: string) =>
      names.map((name) =>
        name === "astro" || name === "astro/jsx-runtime"
          ? undefined
          : ts.resolveModuleName(name, containingFile, options, host).resolvedModule,
      );
    host.fileExists = (name: string) => files.has(name) || exists(name);
    host.getSourceFile = (name: string, version: any, ...args: any[]) =>
      files.has(name)
        ? ts.createSourceFile(name, files.get(name), version, true)
        : get(name, version, ...args);
    const program = ts.createProgram([...files.keys()], options, host);
    const diagnostics = ts.getPreEmitDiagnostics(program);
    assert.deepEqual(
      diagnostics.map((d: any) => d.code),
      expected,
      JSON.stringify(
        diagnostics.map((d: any) => ts.flattenDiagnosticMessageText(d.messageText, "\n")),
      ),
    );
    for (const d of diagnostics) {
      if (d.file?.fileName !== filename) continue;
      const mapping = result.mappings.find(
        ([start, len, , , kind]) => kind === 0 && d.start >= start && d.start < start + len,
      );
      assert.ok(mapping, "TypeScript diagnostic must map back to original Astro source");
      const original = mapping[2] + d.start - mapping[0];
      assert.strictEqual(
        source.slice(original, original + d.length),
        result.code.slice(d.start, d.start + d.length),
      );
    }
  });
}
check(
  "TSX infers nested async getStaticPaths props and params",
  `export async function getStaticPaths() {
    return [[{params: {slug: 'one'}, props: {count: 42}}]];
}
const count: number = Astro.props.count;
const slug: string = Astro.params.slug;`,
  [] as any[],
);
check(
  "TSX type errors map back to original Astro source",
  `export function getStaticPaths() {
    return [{params: {slug: 'one'}, props: {count: 42}}];
}
const count: string = Astro.props.count;
const slug: number = Astro.params.slug;`,
  [2322, 2322],
);
check(
  "TSX explicit Props keeps inferred route params",
  `interface Props { label: string }
export function getStaticPaths() { return [{params: {id: 'one'}, props: {count: 42}}]; }
const label: string = Astro.props.label;
const id: string = Astro.params.id;`,
  [] as any[],
);
check(
  "TSX normalizes TypeScript generics and assertions",
  `const id = <T /* comma: , */>(value: T) => value;
const values = <Array<string>>['hi'];
const value: string = id(values[0]);`,
  [] as any[],
);
