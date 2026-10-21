/* oxlint-disable unicorn/no-new-array -- Binary counts allow preallocation. */
import { createDecoder } from "./estree_nodes.ts";
import { decodeUtf8, utf8Length } from "./encoding.ts";
import { byteIndex } from "./positions.ts";
import { diagnostic, layout } from "./transfer_nodes.ts";
import type { Reader } from "./transfer_decode.ts";
import type { InternalAstroDiagnostic, ESTreeNode, ParseResult } from "./types.ts";

/** Build public ESTree nodes directly from the shared Yuku/Astro transfer buffer. */
export default function estree(r: Reader, littleEndian?: boolean): ParseResult {
  const header = r.open(littleEndian);
  const source = r.source;
  const sourceLength = header[3];
  const documentStart = r.cursor;
  const firstNonAscii = r.firstNonAscii;
  const offsets =
    firstNonAscii < sourceLength
      ? (r.offsets ??= byteIndex(source, sourceLength, firstNonAscii))
      : null;
  const pos = (byte: number) => (byte <= firstNonAscii ? byte : offsets![byte - firstNonAscii]);
  const slice = (start: number, end: number) => source.slice(pos(start), pos(end));
  const word = (offset: number) => r.view.getUint32(offset, true);
  function record(type: string, start: number, end: number, fields = {}): ESTreeNode {
    const node = fields as ESTreeNode;
    node.type = type;
    node.start = pos(start);
    node.end = pos(end);
    return node;
  }

  r.u32(); // The public body uses its nodes' positions, not template_start.
  const hasFrontmatter = r.u8();
  const frontmatterStart = hasFrontmatter ? r.u32() : 0;
  const frontmatterEnd = hasFrontmatter ? r.u32() : 0;
  const frontmatterRoot = hasFrontmatter ? r.u32() : 0;
  const nodeCount = r.u32();
  const nodesEnd = documentStart + r.u32();
  const nodeIndex = r.cursor;
  if (nodeIndex + nodeCount * 8 > nodesEnd || nodesEnd > r.buffer.length)
    throw new Error("Invalid Astro node section size");
  const nodeOffset = (id: number) => documentStart + word(nodeIndex + id * 8);
  const suffixOffset = (id: number) => documentStart + word(nodeIndex + id * 8 + 4);
  r.cursor = nodesEnd;
  const failedIds = r.integers();
  const rootCount = r.u32();
  const roots = r.cursor;
  r.cursor += rootCount * 4;
  const comments: ParseResult["ast"]["comments"] = new Array(r.u32());
  for (let i = 0; i < comments.length; i++) {
    const type = r.string(),
      start = r.u32(),
      end = r.u32(),
      value = r.string();
    comments[i] = { type: type === "line" ? "Line" : "Block", value, start, end };
  }
  const diagnostics: InternalAstroDiagnostic[] = r.array(diagnostic);
  const markup = new Map<number, number>();
  for (let count = r.u32(); count > 0; count--) markup.set(r.u32(), r.u32());
  if (r.cursor !== r.buffer.length) throw new Error("Invalid Astro transfer size");
  const failedRanges = failedIds.map((id) => {
    r.cursor = nodeOffset(id) + 4;
    r.skipString();
    return { start: r.root(), end: r.root() };
  });
  for (let i = 0, offset = r.commentOffset; i < header[4]; i++, offset += layout.COMMENT_SIZE) {
    const nativeWord = (field: number) => r.view.getUint32(offset + field, r.littleEndian);
    const start = nativeWord(layout.COMMENT_VALUE_START_OFFSET);
    const end = nativeWord(layout.COMMENT_VALUE_END_OFFSET);
    comments.push({
      type: r.view.getUint8(offset + layout.COMMENT_FLAGS_OFFSET) & 1 ? "Block" : "Line",
      value:
        start < sourceLength
          ? slice(start, end)
          : decodeUtf8(
              r.buffer.subarray(
                r.poolOffset + start - sourceLength,
                r.poolOffset + end - sourceLength,
              ),
            ),
      start: nativeWord(layout.COMMENT_SPAN_START_OFFSET),
      end: nativeWord(layout.COMMENT_SPAN_END_OFFSET),
    });
  }
  comments.sort((a, b) => a.start - b.start);
  let commentCount = 0,
    previousStart = -1,
    previousEnd = -1;
  for (const comment of comments) {
    const start = comment.start,
      end = comment.end;
    if (start === previousStart && end === previousEnd) continue;
    previousStart = start;
    previousEnd = end;
    if (failedRanges.some((range) => range.start! <= start && range.end! >= end)) {
      let visible = false;
      for (let id = 0; id < nodeCount && !visible; id++) visible = allowsComment(id, start, end);
      if (!visible) continue;
    }
    comment.start = pos(start);
    comment.end = pos(end);
    comments[commentCount++] = comment;
  }
  comments.length = commentCount;
  const js: (id: number) => ESTreeNode | null = createDecoder(
    r.view.buffer,
    source,
    markup,
    astro,
    offsets,
  );

  function programFor(id: number, start: number, end: number): ESTreeNode {
    const program = js(id)!;
    if (
      (!program.body.length &&
        diagnostics.some(
          (d) => d.severity === "error" && d.start !== null && d.start >= start && d.start <= end,
        )) ||
      failedRanges.some((range) => range.start! >= start && range.end! <= end)
    ) {
      program.body = [];
      program.start = 0;
      program.end = 0;
    } else {
      program.start = pos(r.firstTokenStart(start, end));
      program.end = pos(end);
    }
    return program;
  }

  function nodeType(id: number) {
    r.cursor = nodeOffset(id) + 4;
    return r.string();
  }

  function allowsComment(id: number, start: number, end: number) {
    const type = nodeType(id);
    r.skipRoot();
    r.skipRoot();
    r.skipString();
    r.skipIntegers();
    if (r.u8()) r.skipString();
    if (r.u8()) r.skipString();
    const valueStart = r.root(),
      valueEnd = r.root();
    r.cursor = suffixOffset(id) + 4;
    const openingEnd = r.root();
    r.skipRoot();
    const nameEnd = r.root();
    return (
      ((type === "Expression" || type === "Script") && valueStart! <= start && valueEnd! >= end) ||
      (nameEnd !== null && nameEnd <= start && openingEnd! >= end)
    );
  }

  function childrenAt(offset: number, count: number, skipClosing = true): ESTreeNode[] {
    const result: ESTreeNode[] = [];
    for (let i = 0; i < count; i++) {
      const id = word(offset + i * 4);
      if (!skipClosing || nodeType(id) !== "ClosingTag") result.push(astro(id));
    }
    return result;
  }

  function name(value: string, start: number): ESTreeNode {
    if (!/[.\s]/u.test(value))
      return record("JSXIdentifier", start, start + utf8Length(value), { name: value });
    const parts = [...value.matchAll(/[^.\s]+/gu)];
    const first = parts[0]?.[0] ?? "";
    let result = record("JSXIdentifier", start, start + utf8Length(first), { name: first });
    let cursor = start + utf8Length(first);
    for (const part of parts.slice(1)) {
      const begin = start + utf8Length(value.slice(0, part.index));
      cursor = begin + utf8Length(part[0]);
      const property = record("JSXIdentifier", begin, cursor, { name: part[0] });
      result = record("JSXMemberExpression", start, cursor, { object: result, property });
    }
    return result;
  }

  function attribute(
    kind: string,
    attributeName: string | null,
    attributeValue: string | null,
    start: number,
    end: number,
    valueStart: number | null,
    valueEnd: number | null,
    expressionId: number | null,
    nameStart: number | null,
    nameEnd: number | null,
    literalStart: number | null,
    literalEnd: number | null,
  ): ESTreeNode {
    const expression = expressionId === null ? null : astro(expressionId);
    if (kind === "spread")
      return record("JSXSpreadAttribute", start, end, { argument: expression?.expression });
    let value: ESTreeNode | null = null;
    if (kind === "quoted" || kind === "unquoted") {
      const begin = literalStart ?? valueStart ?? start;
      const finish = literalEnd ?? valueEnd ?? end;
      value = record("Literal", begin, finish, {
        value: attributeValue,
        raw: kind === "quoted" ? slice(begin, finish) : null,
      });
    } else if (expression) value = expression;
    const inner = expression?.expression;
    const shorthand = kind === "shorthand";
    if (shorthand && inner && inner.type !== "Identifier") {
      expression!.start = inner.start;
      expression!.end = inner.end;
    }
    return record("JSXAttribute", start, end, {
      name:
        shorthand && inner?.type === "Identifier"
          ? { type: "JSXIdentifier", name: inner.name, start: inner.start, end: inner.end }
          : record("JSXIdentifier", nameStart ?? start, nameEnd ?? end, {
              name: decodeName(attributeName ?? ""),
            }),
      value,
    });
  }

  function decodeName(value: string): string {
    // Match the published wrapper's raw attribute-name escaping and SyntaxError.
    // oxlint-disable-next-line no-control-regex -- JSON rejects unescaped control characters.
    return /["\\\u0000-\u001f]/u.test(value) ? JSON.parse('"' + value + '"') : value;
  }

  function attributesAt(offset: number): ESTreeNode[] {
    r.cursor = offset;
    const count = r.u32();
    const result: ESTreeNode[] = [];
    for (let i = 0; i < count; i++) {
      const kind = r.string();
      const name = r.u8() ? r.string() : null,
        value = r.u8() ? r.string() : null;
      r.skipString(); // raw is not a public attribute field.
      const start = r.u32(),
        end = r.u32(),
        valueStart = r.root(),
        valueEnd = r.root();
      const expression = r.root(),
        nameStart = r.root(),
        nameEnd = r.root();
      const literalStart = r.root(),
        literalEnd = r.root(),
        next = r.cursor;
      if (kind !== "comment") {
        if (kind === "unquoted" && value?.startsWith("=")) {
          const split = nameEnd ?? start;
          result.push(
            attribute(
              "boolean",
              name,
              value,
              start,
              split,
              valueStart,
              valueEnd,
              expression,
              nameStart,
              nameEnd,
              literalStart,
              literalEnd,
            ),
          );
          result.push(
            attribute(
              kind,
              "=",
              value.slice(1),
              split,
              end,
              valueStart! + 1,
              valueEnd,
              expression,
              split,
              split + 1,
              literalStart! + 1,
              literalEnd,
            ),
          );
        } else
          result.push(
            attribute(
              kind,
              name,
              value,
              start,
              end,
              valueStart,
              valueEnd,
              expression,
              nameStart,
              nameEnd,
              literalStart,
              literalEnd,
            ),
          );
      }
      r.cursor = next;
    }
    return result;
  }

  function fragment(
    start: number,
    end: number,
    children: ESTreeNode[],
    openingEnd = start,
    closingStart = end,
  ) {
    return record("JSXFragment", start, end, {
      openingFragment: record("JSXOpeningFragment", start, openingEnd),
      children,
      closingFragment: record("JSXClosingFragment", closingStart, end),
    });
  }

  function astro(id: number): ESTreeNode {
    r.cursor = nodeOffset(id) + 4;
    const type = r.string(),
      start = r.root() ?? 0,
      end = r.root() ?? start;
    if (type === "Text") {
      const text = r.string();
      r.skipIntegers();
      if (r.u8()) r.skipString();
      return record("JSXText", start, end, { value: r.u8() ? r.string() : text, raw: text });
    }
    if (type === "Comment" || type === "Doctype") {
      r.skipString();
      r.skipIntegers();
      if (r.u8()) r.skipString();
      return record(type === "Comment" ? "AstroComment" : "AstroDoctype", start, end, {
        value: r.u8() ? r.string() : "",
      });
    }
    r.skipString();
    const childCount = r.u32(),
      children = r.cursor;
    r.cursor += childCount * 4;
    const nodeName = r.u8() ? r.string() : null;
    if (r.u8()) r.skipString();
    const valueStart = r.root(),
      valueEnd = r.root(),
      attrs = r.cursor;
    r.cursor = suffixOffset(id);
    const selfClosing = !!r.u8(),
      implicitVoid = !!r.u8(),
      closed = !!r.u8(),
      raw = !!r.u8();
    const openingEnd = r.root(),
      nameStart = r.root();
    r.skipRoot();
    const closingStart = r.root(),
      closingEnd = r.root(),
      closingNameStart = r.root(),
      closingNameEnd = r.root();
    const implicitFragment = !!r.u8(),
      spread = !!r.u8(),
      parseFailed = !!r.u8();
    const javascript = r.root(),
      typeArguments = r.root();
    const recoveredRaw = raw && type !== "Script" && !closed && closingNameStart === 0;
    if (parseFailed && !recoveredRaw && (type !== "Fragment" || nodeName !== null)) {
      return record("JSXElement", 0, 0, {
        openingElement: record("JSXOpeningElement", 0, 0, {
          name: record("JSXIdentifier", 0, 0, { name: "this" }),
          typeArguments: null,
          attributes: [],
          selfClosing: true,
        }),
        children: [],
        closingElement: null,
      });
    }
    switch (type) {
      case "Expression": {
        let expression = javascript === null ? null : js(javascript);
        if (!expression && childCount === 1 && nodeType(word(children)) !== "Comment")
          expression = astro(word(children));
        else if (!expression && childCount)
          expression = fragment(valueStart ?? start + 1, end, childrenAt(children, childCount));
        expression ??= record("JSXEmptyExpression", valueStart ?? start + 1, valueEnd ?? end - 1);
        return record(spread ? "JSXSpreadChild" : "JSXExpressionContainer", start, end, {
          expression,
        });
      }
      case "Fragment":
        if (nodeName === null) {
          const content = childrenAt(children, childCount, false);
          if (implicitFragment) return fragment(start, end, content);
          const value = fragment(start, end, content, openingEnd ?? start, closingStart ?? 0);
          if (closingStart === null) value.closingFragment.end = 0;
          return value;
        }
      // Named <Fragment> is an ordinary JSXElement.
      // fall through
      default: {
        const openingElement = record("JSXOpeningElement", start, openingEnd ?? end, {
          name: name(nodeName ?? "", nameStart ?? start + 1),
          typeArguments: typeArguments === null ? null : js(typeArguments),
          attributes: attributesAt(attrs),
          selfClosing: selfClosing || implicitVoid,
        });
        const closingElement =
          closingStart === null
            ? null
            : record("JSXClosingElement", closingStart, closingEnd ?? end, {
                name: name(
                  type === "Script" || type === "Style"
                    ? (nodeName ?? "")
                    : slice(closingNameStart!, closingNameEnd!),
                  closingNameStart ?? closingStart + 2,
                ),
              });
        if (closingElement && (type === "Script" || type === "Style"))
          closingElement.name.end = pos((closingEnd ?? end) - 1);
        if (closingElement && recoveredRaw)
          closingElement.name = record("JSXIdentifier", 0, 0, { name: "this" });
        const content =
          type === "Script" && javascript !== null
            ? [
                record("AstroScript", start, end, {
                  program: programFor(javascript, valueStart ?? start, valueEnd ?? end),
                }),
              ]
            : childrenAt(children, childCount);
        return record("JSXElement", start, end, {
          openingElement,
          children: content,
          closingElement,
        });
      }
    }
  }

  return {
    ast: {
      type: "AstroRoot",
      frontmatter: {
        type: "AstroFrontmatter",
        program: hasFrontmatter
          ? programFor(frontmatterRoot, frontmatterStart, frontmatterEnd)
          : record("Program", 0, 0, { body: [], sourceType: "module", hashbang: null }),
        start: 0,
        end: hasFrontmatter ? pos(Math.min(sourceLength, frontmatterEnd + 3)) : 0,
      },
      body: childrenAt(roots, rootCount),
      comments,
      start: 0,
      end: source.length,
    },
    diagnostics: diagnostics.map((diagnostic) => ({
      severity:
        diagnostic.severity === "info"
          ? "information"
          : (diagnostic.severity as "error" | "warning" | "hint"),
      text: diagnostic.message,
      hint: diagnostic.help ?? "",
      labels: (diagnostic.labels.length
        ? diagnostic.labels.map((label) => ({
            text: label.message || null,
            start: label.span.start,
            end: label.span.end,
          }))
        : diagnostic.start === null
          ? []
          : [{ text: null, start: diagnostic.start, end: diagnostic.end ?? diagnostic.start }]
      ).map((label) => {
        const lines = slice(0, label.start).split(/\r\n|\r|\n/);
        return { ...label, line: lines.length, column: Array.from(lines.at(-1)!).length };
      }),
    })),
  };
}
