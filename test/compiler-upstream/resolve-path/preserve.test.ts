// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { assert, beforeAll as before, describe, it } from "vite-plus/test";
import { type TransformResult, transform } from "../../../dist/index.mjs";
import { transform as transformAsync } from "../async.ts";

const FIXTURE = `
---
import Foo from './Foo.jsx'
import Bar from './Bar.jsx'
import { name } from './foo.module.css'
---
<Foo />
<Foo client:load />
<Foo client:only="react" />
`;

let result: TransformResult;

describe("resolve-path/preserve", () => {
  before(() => {
    result = transform(FIXTURE, {
      resolvePath: (s) => s,
    });
  });

  it("preserve path", () => {
    assert.match(result.code, /"client:load": true[\s\S]*"client:component-path": "\.\/Foo\.jsx"/);
    assert.match(
      result.code,
      /"client:only": "react"[\s\S]*"client:component-path": "\.\/Foo\.jsx"/,
    );
  });

  it("no metadata", () => {
    assert.notMatch(result.code, /\$\$metadata/);
    assert.notMatch(result.code, /\$\$createMetadata/);
    assert.notMatch(result.code, /createMetadata as \$\$createMetadata/);
    assert.notMatch(result.code, /import \* as \$\$module\d/);
  });

  it("resolvePath rewrites code string (async)", async () => {
    const resolved = await transformAsync(FIXTURE, {
      resolvePath: async (s) => `/resolved${s.slice(1)}`,
    });
    assert.match(resolved.code, /"client:component-path": "\/resolved\/Foo\.jsx"/);
    assert.notMatch(resolved.code, /"client:component-path": "\.\/Foo\.jsx"/);
  });

  it("resolvePath rewrites code string (sync)", () => {
    const resolved = transform(FIXTURE, {
      resolvePath: (s) => `/resolved${s.slice(1)}`,
    });
    assert.match(resolved.code, /"client:component-path": "\/resolved\/Foo\.jsx"/);
    assert.notMatch(resolved.code, /"client:component-path": "\.\/Foo\.jsx"/);
  });
});
