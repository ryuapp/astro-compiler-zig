// Ported from withastro/compiler-rs (MIT); see test/fixtures/compiler-upstream.json and LICENSE.
import { parse } from "../../../../dist/index.mjs";
import { assert, describe, it } from "vite-plus/test";

const FIXTURE = `{
	headers && (
		<nav class="mobile-toc">
			<TableOfContents
				client:media="(max-width: 72em)"
				headers={headers}
				labels={{ onThisPage: t('rightSidebar.onThisPage'), overview: t('rightSidebar.overview') }}
				isMobile={true}
			/>
		</nav>
	)
}
`;

describe("parse/client-component-unfound", () => {
  it("unfound client component", async () => {
    const result = await parse(FIXTURE);
    assert.ok(result.ast, "Expected an AST to be generated");
  });
});
