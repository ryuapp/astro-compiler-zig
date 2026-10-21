# astro-compiler-zig

Unofficial Astro compiler, written in Zig.

## Usage

#### Transform `.astro` to JavaScript

The Astro compiler transforms `.astro` component files into JavaScript modules whose default export generates HTML.

```ts
import { transform } from "astro-compiler-zig";
const result = transform(source, {
  filename: "/Users/astro/project/src/pages/index.astro",
  sourcemap: "both",
});
```

Scoped styles rewrite selectors for component isolation while preserving declaration values and at-rule conditions. CSS formatting and minification are left to the build pipeline.

#### Parse `.astro` and return an AST

The compiler can emit an ESTree-compatible AST using the `parse` method.

```ts
import { parse } from "astro-compiler-zig";
const result = parse(source);
console.log(JSON.stringify(result.ast, null, 2));
```

#### Convert `.astro` to TSX

Generate TSX and UTF-16 span mappings for TypeScript editor tooling. Built against `@astrojs/astro2tsx`.

```ts
import { convertToTsx } from "astro-compiler-zig";
const result = convertToTsx(source, {
  filename: "/Users/astro/project/src/pages/index.astro",
  ambientTypes: true,
});
console.log(result.code);
```

#### Preprocess styles

Provide a synchronous or asynchronous callback for style blocks, then pass the result to `transform`. This example uses `sass`, installed separately. Returning `null` keeps the original CSS.

```ts
import { preprocessStyles, transform } from "astro-compiler-zig";
import { compileStringAsync } from "sass";
const preprocessedStyles = await preprocessStyles(source, async (content, attrs) => {
  if (attrs.lang !== "scss") return null;
  const { css } = await compileStringAsync(content);
  return { code: css };
});
const result = transform(source, {
  preprocessedStyles,
  sourcemap: "both",
});
```

## License

MIT
