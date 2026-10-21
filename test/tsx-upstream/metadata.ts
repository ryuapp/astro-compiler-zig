import { upstream, assert, convert, slice } from "./helpers.ts";
upstream(
  "tests/metadata.rs",
  "generated_section_ranges_exclude_fences_and_fragment_wrappers",
  () => {
    for (const [source, frontmatter, body, status] of [
      [
        '---\nconsole.log("Hello!")\n---\n\n<div></div>',
        '\nconsole.log("Hello!")\n\n',
        "\n\n<div></div>\n",
        "closed",
      ],
      ["<div></div>", "", "<div></div>\n", "doesnt-exist"],
      ["---\n🦄\n---\n\n<div></div>", "\n🦄\n\n", "\n\n<div></div>\n", "closed"],
    ]) {
      const result = convert(source);
      assert.equal(slice(result.code, result.frontmatter), frontmatter);
      assert.equal(slice(result.code, result.body), body);
      assert.ok(result.code.slice(0, result.body.start).endsWith("<Fragment>\n"));
      assert.ok(result.code.slice(result.body.end).startsWith("</Fragment>"));
      assert.equal(result.frontmatterStatus, status);
      assert.equal(result.scripts.length, 0);
      assert.equal(result.styles.length, 0);
    }
  },
);
