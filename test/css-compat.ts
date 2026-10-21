import { transform } from "@astrojs/compiler-rs";

// Compare complete CSS after the reference parser/printer normalizes formatting,
// values and implicit nesting. Production output deliberately retains declarations.
export function canonicalCss(css: string): string {
  return (
    transform("<style/>", {
      filename: "/__css_comparison__.astro",
      preprocessedStyles: { styles: [css], styleError: [] },
    }).css[0] ?? ""
  );
}
