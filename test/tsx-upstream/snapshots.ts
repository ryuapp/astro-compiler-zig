import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import {
  upstream,
  assert,
  convert,
  absent,
  assertSyntax,
  assertVerbatim,
  fixture,
  fixtureDirectory,
} from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("tests/snapshots.rs", name, body);
const names = readdirSync(fixtureDirectory).filter((name) => name.endsWith(".astro"));
test("snapshots", () => {
  assert.equal(names.length, 74);
  for (const name of names) {
    const { source, options } = fixture(name);
    const snapshot = readFileSync(
      join(fixtureDirectory, name.replace(/\.astro$/, ".snap")),
      "utf8",
    ).replaceAll("\r\n", "\n");
    const separator = snapshot.indexOf("\n---\n");
    assert.ok(separator >= 0, name);
    assert.equal(
      convert(source, options).code.replaceAll("\r\n", "\n"),
      snapshot.slice(separator + 5),
      name,
    );
  }
});
test("crlf_fixture_keeps_its_line_endings", () => {
  const { source, options } = fixture("crlf_frontmatter.astro");
  assert.ok(source.includes("\r\n"));
  assert.equal(source.match(/\n/g)?.length, source.match(/\r\n/g)?.length);
  const result = convert(source, options);
  for (const line of source.split("\r\n")) {
    if (!line || line === "---") continue;
    assert.ok(result.code.includes(line + "\r\n"), JSON.stringify(line));
  }
});
test("every_fixture_keeps_mapped_runs_verbatim", () => {
  let checked = 0;
  for (const name of names) {
    const { source, options } = fixture(name);
    const result = convert(source, options);
    assertVerbatim(source, result);
    if (!result.hasParseErrors) assertSyntax(result.code);
    checked++;
  }
  assert.ok(checked > 50);
});
test("stripping_the_doctype_keeps_mapped_runs_verbatim", () => {
  const source =
    '---\nconst é = 1;\n---\n\n<!doctype html>\n<html lang=en data-x="𝒳"><body>{é}</body></html>\n';
  for (const ambientTypes of [false, true]) {
    const result = convert(source, { ambientTypes });
    absent(result.code, "<!");
    assertVerbatim(source, result);
  }
});
