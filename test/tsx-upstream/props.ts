import { upstream, clean, contains, absent } from "./helpers.ts";
const test = (name: string, body: () => void) => upstream("src/props.rs", name, body);
test("aliases_do_not_inherit_nested_type_parameters", () => {
  for (const fields of ["", "src: Promise<{ default: string }>;"])
    contains(
      clean("---\ninterface LocalImageProps { " + fields + " }\ntype Props = LocalImageProps;\n---")
        .code,
      "function AstroComponent(_props: Props)",
    );
});
test("nested_generic_constraints_are_preserved", () => {
  contains(
    clean("---\ninterface Props<T extends Other<{ [key: string]: any }>> {}\n---\n<div/>").code,
    "function AstroComponent<T extends Other<{ [key: string]: any }>>(_props: Props<T>)",
  );
});
test("props_names_and_export_bindings_are_scope_aware", () => {
  for (const declaration of [
    "declare interface Props { value: string }",
    "export declare interface Props { value: string }",
    "interface Pr\\u006fps { value: string }",
    "import type { Other as Pr\\u006fps } from './types';",
  ])
    contains(clean("---\n" + declaration + "\n---").code, "_props: Props");
  for (const binding of [
    "{ paths = (() => { const getStaticPaths = () => []; return getStaticPaths; })() }",
    "{ [(() => { const getStaticPaths = 'paths'; return getStaticPaths; })()]: paths }",
  ])
    absent(
      clean("---\nexport const " + binding + " = {};\n---").code,
      "ReturnType<typeof getStaticPaths>",
    );
  for (const binding of [
    "{ getStaticPaths }",
    "{ paths: getStaticPaths }",
    "[getStaticPaths = () => []]",
    "{ nested: { getStaticPaths } }",
  ])
    contains(
      clean("---\nexport const " + binding + " = data;\n---").code,
      "ReturnType<typeof getStaticPaths>",
    );
});
