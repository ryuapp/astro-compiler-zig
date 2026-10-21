# Project guidance

- Breaking changes are acceptable. Avoid compatibility-only flags, legacy paths, and extra scripts.
- Keep Yuku's shared arena and avoid parsing the same region twice on the normal path.
- Keep Yuku as the architectural baseline, including binary transfer and JS AST restoration. Prefer upstream-aligned optimizations and keep Astro-specific adaptations narrow.
- Before allocation or performance changes, inspect the pinned Yuku implementation and follow its approach where applicable.
- Use strict TypeScript, ESM, and bundled WASM without npm runtime dependencies. Keep tasks in `vite.config.ts`.
- Follow `.node-version` and the Zig version in `build.zig.zon`. Commit or publish only when requested.

## Debugging

- Reproduce with `vp test`, group failures by cause, and reduce to a minimal input. For large reports: `vp test --reporter=json --outputFile=.tmp/vitest-failures.json`.
- Iterate with `vp test test/<name>.test.ts`. Fix behavior rather than weakening assertions or adding skips.
- After TypeScript or Zig changes, wait for `vp pack` to finish before testing: public tests and benchmarks load the built package from `dist/`. The command also creates the release tarball there.
- Compare against the installed `@astrojs/compiler-rs` and `@astrojs/astro2tsx`. Check complete ASTs, code, mappings, extracted data, and error status; diagnostic wording may differ.
- Check UTF-8 byte offsets versus UTF-16 positions with emoji, CRLF, and incomplete syntax. Prioritize transform maps with `sourcemap: "both"`.
- When updating reference packages, update behavior and fixture provenance together. Capture expected results from the official implementation.
- `typescript-compat` supplies the legacy JS Compiler API (currently 5.5.4). Moving it to 7 requires migrating API usage in generators and tests.
- Regenerate `src/*_nodes.ts` and `src/tsx_data.zig` through `vp run sync`, using pinned upstream commits.
- Test compiler behavior and regressions. Do not add command wrappers or tests of packaging, fixture hashes, or regenerated source-file equality.
- After behavior changes, run focused tests, `vp check`, and `vp test`; rebuild with `vp pack` when WASM changes.

## Benchmarks

- Use `vp run bench`; verify equivalent output and include public `parse()` through JS AST restoration.
- Separate imports, first calls, and warmed measurements. Match arena reuse conditions; multiplying one call's time is not a measured batch.
