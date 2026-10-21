import { upstream, assert, convert, contains, absent } from "./helpers.ts";
import events from "../../src/html_event_attributes.json" with { type: "json" };
const test = (name: string, body: () => void) => upstream("src/utils.rs", name, body);
test("html_event_attributes_are_sorted", () => assert.deepEqual(events, [...events].sort()));
test("component_names_match_editor_exports", () => {
  for (const [filename, component, alias] of [
    ["MyPage.astro", "MyPageAstroComponent", "MyPage"],
    ["image.astro", "ImageAstroComponent", "Image"],
    ["my-comp.astro", "MyCompAstroComponent", "MyComp"],
    ["my_comp.astro", "MyCompAstroComponent", "MyComp"],
    ["file:///src/MyPage.astro", "MyPageAstroComponent", "MyPage"],
    ["[slug].astro", "_Slug_AstroComponent", undefined],
    ["404.astro", "FourOhFourAstroComponent", undefined],
    ["[...path].astro", "AstroComponent", undefined],
    ["123.astro", "AstroComponent", undefined],
    [".astro", "AstroComponent", undefined],
    ["My.Page.astro", "MyAstroComponent", undefined],
    ["Ünicorn.astro", "ÜnicornAstroComponent", undefined],
    ["", "AstroComponent", undefined],
    ["<stdin>", "AstroComponent", undefined],
    [undefined, "AstroComponent", undefined],
  ]) {
    const result = convert("", { filename });
    contains(result.code, "function " + component + "(");
    if (alias) contains(result.code, "export { " + component + " as " + alias + " };");
    else {
      assert.equal(result.generatedComponentExport, undefined);
      absent(result.code, "export {");
    }
  }
});
test("windows_paths_use_the_filename_for_component_names", () => {
  const result = convert("<p/>", { filename: "C:\\repo\\src\\MyPage.astro" });
  contains(result.code, "function MyPageAstroComponent(");
  contains(result.code, "export { MyPageAstroComponent as MyPage };");
});
