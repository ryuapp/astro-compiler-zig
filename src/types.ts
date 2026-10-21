/** Source ranges are absolute UTF-8 byte offsets, with an exclusive end. */
export interface AstroAttribute {
  kind: string;
  name: string | null;
  value: string | null;
  raw: string;
  start: number;
  end: number;
  valueStart: number | null;
  valueEnd: number | null;
  expression: number | null;
  nameStart: number | null;
  nameEnd: number | null;
  literalStart: number | null;
  literalEnd: number | null;
}

export interface AstroNode {
  id: number;
  typeName: string;
  start: number | null;
  end: number | null;
  text: string;
  children: number[];
  name: string | null;
  value: string | null;
  valueStart: number | null;
  valueEnd: number | null;
  attributes: AstroAttribute[];
  selfClosing: boolean;
  implicitVoid: boolean;
  closed: boolean;
  raw: boolean;
  openingEnd: number | null;
  nameStart: number | null;
  nameEnd: number | null;
  closingStart: number | null;
  closingEnd: number | null;
  closingNameStart: number | null;
  closingNameEnd: number | null;
  implicitFragment: boolean;
  spread: boolean;
  parseFailed: boolean;
}

export interface InternalAstroDiagnostic {
  region: string;
  severity: string;
  message: string;
  start: number | null;
  end: number | null;
  help: string | null;
  labels: { span: YukuSpan; message: string }[];
}

/** Absolute UTF-8 byte offsets, with an exclusive end. */
export interface YukuSpan {
  start: number;
  end: number;
}

/** Yuku String handle into source bytes or strings.extra, offset by source byte length. */
export interface YukuString {
  start: number;
  end: number;
}

export interface YukuIndexRange {
  start: number;
  len: number;
}

export type YukuField =
  | string
  | number
  | boolean
  | null
  | YukuField[]
  | {
      [field: string]: YukuField;
    };

export interface YukuNode {
  /** One original NodeData union tag mapped to its complete payload. */
  data: { [tag: string]: { [field: string]: YukuField } };
  span: YukuSpan;
}

export interface YukuDiagnostic {
  severity: "error" | "warning" | "hint" | "info";
  message: string;
  span: YukuSpan;
  help: string | null;
  labels: { span: YukuSpan; message: string }[];
}

/** Yuku Tree data retains its original snake_case field names and node IDs. */
export interface YukuTree {
  /** The document is a forest; its root is NodeIndex.null (0xFFFFFFFF). */
  root: number;
  nodes: YukuNode[];
  extras: number[];
  source: string;
  strings: { extra: number[] };
  source_type: "script" | "module" | "commonjs";
  lang: "js" | "ts" | "jsx" | "tsx" | "dts";
  comments: { type: "line" | "block"; value: YukuString; span: YukuSpan }[];
  tokens: { tag: string; span: YukuSpan; flags: number; _pad: number[] }[];
  diagnostics: YukuDiagnostic[];
  /** Dialect node IDs link directly to ast.template.nodes IDs. */
  markup: { node: number; astro_node: number }[];
}

export interface ParsedAstroNode extends AstroNode {
  /** Root ID in ast.tree; 0xFFFFFFFF for an empty/failed expression, null without JS. */
  javascript: number | null;
  /** Root ID in ast.tree for a generic tag's type arguments, or null without them. */
  typeArguments: number | null;
}

/** Internal transfer snapshot; node IDs and spans are Yuku's UTF-8 representation. */
export interface InternalParseResult {
  ast: {
    type: "AstroRoot";
    start: number;
    end: number;
    /** One Yuku Tree, node ID namespace and string pool for the entire document. */
    tree: YukuTree;
    frontmatter: { start: number; end: number; source: string; root: number } | null;
    template: {
      start: number;
      end: number;
      source: string;
      nodes: ParsedAstroNode[];
      rootIds: number[];
    };
    comments: { type: "line" | "block"; span: YukuSpan; value: string }[];
  };
  diagnostics: InternalAstroDiagnostic[];
}

/** ESTree node with absolute UTF-16 offsets, including Astro's JSX extensions. */
export interface ESTreeNode {
  type: string;
  start: number;
  end: number;
  [field: string]: any;
}

export interface ParseResult {
  ast: ESTreeNode & {
    type: "AstroRoot";
    frontmatter: ESTreeNode & { type: "AstroFrontmatter"; program: ESTreeNode };
    body: ESTreeNode[];
    comments: (ESTreeNode & { type: "Line" | "Block"; value: string })[];
  };
  diagnostics: DiagnosticMessage[];
}

export type AstroParseResult = ParseResult;

export interface PreprocessorResult {
  code: string;
  map?: string;
}

export interface PreprocessorError {
  error: string;
}

/** Pass this result to transform via options.preprocessedStyles. */
export interface PreprocessedStyles {
  /** Extractable styles in document order; undefined retains the original CSS. */
  styles: (string | undefined)[];
  styleError: string[];
}

export interface TransformOptions {
  filename?: string;
  normalizedFilename?: string;
  internalURL?: string;
  sourcemap?: "external" | "inline" | "both";
  astroGlobalArgs?: string;
  compact?: boolean | "jsx";
  resultScopedSlot?: boolean;
  scopedStyleStrategy?: "where" | "class" | "attribute";
  transitionsAnimationURL?: string;
  annotateSourceFile?: boolean;
  stripSlotComments?: boolean;
  inlineComponentAssets?: boolean;
  resolvePath?: (specifier: string) => string;
  /** Output of preprocessStyles, indexed by extractable style order. */
  preprocessedStyles?: PreprocessedStyles;
}
export interface Component {
  exportName: string;
  localName: string;
  specifier: string;
  resolvedPath: string;
}
export interface HoistedScript {
  type: "inline" | "external";
  code?: string;
  src?: string;
}
export interface DiagnosticLabel {
  text: string | null;
  start: number;
  end: number;
  line: number;
  column: number;
}
export interface DiagnosticMessage {
  severity: "error" | "warning" | "information" | "hint";
  text: string;
  hint: string;
  labels: DiagnosticLabel[];
}
export interface TransformResult {
  code: string;
  map: string;
  scope: string;
  css: string[];
  scripts: HoistedScript[];
  hydratedComponents: Component[];
  clientOnlyComponents: Component[];
  serverComponents: Component[];
  containsHead: boolean;
  propagation: boolean;
  styleError: string[];
  diagnostics: DiagnosticMessage[];
}
/** Transform Astro into a JavaScript module using Astro's server runtime. */

/** TSX positions use UTF-16 code units, with an exclusive end. */
export interface Range {
  start: number;
  end: number;
}
export const AstroFrontmatterStatus = {
  DoesntExist: "doesnt-exist",
  Open: "open",
  Closed: "closed",
} as const;
export type AstroFrontmatterStatus =
  (typeof AstroFrontmatterStatus)[keyof typeof AstroFrontmatterStatus];
export const DiagnosticSeverity = { Error: 1, Warning: 2, Information: 3, Hint: 4 } as const;
export type DiagnosticSeverity = (typeof DiagnosticSeverity)[keyof typeof DiagnosticSeverity];
export const ExtractedScriptType = {
  ProcessedModule: "processed-module",
  Module: "module",
  Inline: "inline",
  EventAttribute: "event-attribute",
  Json: "json",
  Raw: "raw",
  Unknown: "unknown",
} as const;
export type ExtractedScriptType = (typeof ExtractedScriptType)[keyof typeof ExtractedScriptType];
export const ExtractedStyleType = { Tag: "tag", StyleAttribute: "style-attribute" } as const;
export type ExtractedStyleType = (typeof ExtractedStyleType)[keyof typeof ExtractedStyleType];
export interface ConvertToTsxOptions {
  /** Used for the default component name and optional clean-name re-export. */
  filename?: string;
  /** Add fallback Fragment and Astro declarations; defaults to false. */
  ambientTypes?: boolean;
}
export interface AstroDiagnostic {
  message: string;
  severity: DiagnosticSeverity;
  position: Range;
}
export interface ExtractedScript {
  position: Range;
  content: string;
  type: ExtractedScriptType;
}
export interface ExtractedStyle {
  position: Range;
  content: string;
  type: ExtractedStyleType;
  lang: string;
}
export type TsxMapping = [
  virtualStart: number,
  virtualLength: number,
  originalStart: number,
  originalLength: number,
  kind: 0 | 1 | 2,
  features?: number,
];
export interface ConvertToTsxResult {
  code: string;
  /** TypeScript Content Mapper mappings; offsets and lengths are UTF-16. */
  mappings: TsxMapping[];
  frontmatter: Range;
  body: Range;
  frontmatterStatus: AstroFrontmatterStatus;
  frontmatterSource: Range;
  generatedComponentExport?: Range;
  scripts: ExtractedScript[];
  styles: ExtractedStyle[];
  diagnostics: AstroDiagnostic[];
  hasParseErrors: boolean;
}
/** Generate TSX for editor tooling, retaining recoverable errors as positioned diagnostics. */
