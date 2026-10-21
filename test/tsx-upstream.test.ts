import { afterAll } from "vite-plus/test";
import { readFileSync } from "node:fs";
import { assert, registered } from "./tsx-upstream/helpers.ts";
import origin from "./fixtures/tsx-upstream/origin.json" with { type: "json" };
import "./tsx-upstream/expression.ts";
import "./tsx-upstream/lib.ts";
import "./tsx-upstream/props.ts";
import "./tsx-upstream/attribute.ts";
import "./tsx-upstream/element.ts";
import "./tsx-upstream/extracted.ts";
import "./tsx-upstream/frontmatter.ts";
import "./tsx-upstream/utils.ts";
import "./tsx-upstream/contract.ts";
import "./tsx-upstream/mappings.ts";
import "./tsx-upstream/metadata.ts";
import "./tsx-upstream/snapshots.ts";

afterAll(() => {
  assert.equal(origin.tests.length, 109);
  assert.deepEqual(
    [...registered].sort(),
    origin.tests
      .filter((item) => item.runner === "vitest")
      .map((item) => item.id)
      .sort(),
  );
  const nativeTests = readFileSync(
    new URL("../src/tsx_upstream_tests.zig", import.meta.url),
    "utf8",
  );
  assert.deepEqual(
    [...nativeTests.matchAll(/^test "([^"]+)"/gm)].map((match) => match[1]).sort(),
    origin.tests
      .filter((item) => item.runner === "zig")
      .map((item) => item.id)
      .sort(),
  );
});
