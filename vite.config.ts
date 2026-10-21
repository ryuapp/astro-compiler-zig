import { defineConfig } from "vite-plus";
import { copyFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import $ from "dax";
import packageJson from "./package.json" with { type: "json" };

const ignored = [
  "zig-pkg/**",
  ".zig-cache/**",
  ".tmp/**",
  "test/upstream/**",
  "test/fixtures/tsx-upstream/**",
  "test/fixtures/transform-upstream/**",
  "test/fixtures/biome/**",
  "zig-out/**",
  "dist/**",
];

export default defineConfig({
  run: {
    cache: false,
    tasks: {
      release: `vp pm stage publish dist/${packageJson.name}-${packageJson.version}.tgz --access public`,
      sync: "node scripts/sync.ts",
      bench: "node --expose-gc scripts/benchmark.ts",
    },
  },
  fmt: {
    singleQuote: false,
    ignorePatterns: [
      ...ignored,
      "test/fixtures/**/*.json",
      "src/*_nodes.ts",
      "src/*.json",
      "LICENSE",
    ],
  },
  lint: {
    // These files are skipped by upstream and assert unimplemented Go diagnostics.
    ignorePatterns: [
      ...ignored,
      "test/fixtures/astro-integration/**",
      "test/compiler-upstream/expected-fails/**",
    ],
    overrides: [
      {
        files: ["test/compiler-upstream/**/*.ts", "test/tsx-upstream-api/**/*.ts"],
        rules: {
          // Preserve upstream's awaitable sync calls, compiler-host callbacks and fixtures.
          "typescript/await-thenable": "off",
          "typescript/unbound-method": "off",
          "no-useless-escape": "off",
        },
      },
    ],
    options: { typeAware: true, typeCheck: true },
  },
  test: {
    server: { deps: { external: [/[/\\]dist[/\\]index\.mjs$/] } },
    include: ["test/**/*.test.ts"],
    exclude: ["test/upstream/**"],
    testTimeout: 20000,
    pool: "threads",
    isolate: false,
  },
  pack: {
    entry: "src/index.ts",
    outDir: "dist",
    format: ["esm"],
    fixedExtension: true,
    platform: "node",
    target: "node24.5",
    banner: { js: 'import source wasm from "./compiler.wasm";' },
    dts: true,
    clean: true,
    hooks: {
      async "build:prepare"() {
        await $`zig build install -Doptimize=fast --summary all`.cwd(import.meta.dirname);
      },
    },
    async onSuccess() {
      copyFileSync(
        join(import.meta.dirname, "zig-out/bin/compiler.wasm"),
        join(import.meta.dirname, "dist/compiler.wasm"),
      );
      for (const file of ["LICENSE", "README.md"]) {
        copyFileSync(join(import.meta.dirname, file), join(import.meta.dirname, "dist", file));
      }
      const {
        devDependencies: _devDependencies,
        packageManager: _packageManager,
        ...manifest
      } = packageJson;
      writeFileSync(
        join(import.meta.dirname, "dist/package.json"),
        JSON.stringify(manifest, null, 2) + "\n",
      );
      await $`vp pm pack --pack-destination .`.cwd(join(import.meta.dirname, "dist"));
    },
  },
});
