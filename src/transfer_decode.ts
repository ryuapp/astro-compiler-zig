// Transfer headers provide array lengths; preallocation avoids growing decoded AST arrays.
/* oxlint-disable unicorn/no-new-array */
import * as schema from "./transfer_nodes.ts";
import { byteIndex } from "./positions.ts";
import { decodeUtf8, utf8Length } from "./encoding.ts";
const nativeLittleEndian = new Uint8Array(new Uint16Array([1]).buffer)[0] === 1;
// Yuku's fixed records use host byte order; diagnostics and Astro records use little endian.
function words(
  buffer: ArrayBuffer,
  offset: number,
  count: number,
  littleEndian: boolean,
): Uint32Array {
  if (nativeLittleEndian && littleEndian) return new Uint32Array(buffer, offset, count);
  const view = new DataView(buffer, offset, count * 4);
  const result = new Uint32Array(count);
  for (let i = 0; i < count; i++) result[i] = view.getUint32(i * 4, littleEndian);
  return result;
}
function integers(view: ArrayLike<number>) {
  const result = new Array(view.length);
  for (let index = 0; index < result.length; index++) result[index] = view[index];
  return result;
}
const severities = ["error", "warning", "hint", "info"];
const commentPositions = ["before", "after", "inside"];
const layout = schema.layout;
export class Reader {
  declare buffer: Uint8Array<ArrayBuffer>;
  declare source: string;
  declare offsets: Uint32Array | null;
  declare view: DataView<ArrayBuffer>;
  declare cursor: number;
  declare sourceLength: number;
  declare firstNonAscii: number;
  declare tokenOffset: number;
  declare tokenWords: Uint32Array;
  declare poolOffset: number;
  declare commentOffset: number;
  declare littleEndian: boolean;

  constructor(buffer: ArrayBuffer, source: string, offset = 0) {
    this.buffer = new Uint8Array(buffer);
    this.source = source.toWellFormed();
    this.offsets = null;
    this.view = new DataView(buffer);
    this.cursor = offset;
  }
  u8() {
    return this.view.getUint8(this.cursor++);
  }
  u32() {
    const result = this.view.getUint32(this.cursor, true);
    this.cursor += 4;
    return result;
  }
  slice(start: number, end: number) {
    const first = this.firstNonAscii;
    if (end <= first) return this.source.slice(start, end);
    const offsets = (this.offsets ??= byteIndex(this.source, this.sourceLength, first));
    return this.source.slice(start <= first ? start : offsets[start - first], offsets[end - first]);
  }
  text() {
    const length = this.u32(),
      start = this.cursor;
    this.cursor += length;
    return decodeUtf8(this.buffer.subarray(start, this.cursor));
  }
  string() {
    switch (this.u8()) {
      case 0:
        return this.slice(this.u32(), this.u32());
      case 1:
        return schema.dictionary[this.u8()];
      case 2:
        return this.text();
      default:
        throw new Error("Invalid Astro string encoding");
    }
  }
  array(read: any) {
    const result = new Array(this.u32());
    for (let i = 0; i < result.length; i++) result[i] = read(this);
    return result;
  }
  integers() {
    const result = new Array(this.u32());
    for (let i = 0; i < result.length; i++) result[i] = this.u32();
    return result;
  }
  root() {
    return this.u8() ? this.u32() : null;
  }
  skipString() {
    switch (this.u8()) {
      case 0:
        this.cursor += 8;
        break;
      case 1:
        this.cursor++;
        break;
      case 2: {
        const length = this.u32();
        this.cursor += length;
        break;
      }
      default:
        throw new Error("Invalid Astro string encoding");
    }
  }
  skipRoot() {
    if (this.u8()) this.cursor += 4;
  }
  skipIntegers() {
    const count = this.u32();
    this.cursor += count * 4;
  }
  open(littleEndian = nativeLittleEndian) {
    this.littleEndian = littleEndian;
    if (this.u32() !== 0x41535452 || this.u32() !== 2)
      throw new Error("Unsupported Astro transfer format");
    const treeEnd = 12 + this.u32();
    const header = words(this.view.buffer, 12, layout.HEADER_SIZE / 4, littleEndian);
    if (header[3] !== this.source.length) throw new Error("Transfer source length mismatch");
    if (treeEnd > this.buffer.length) throw new Error("Truncated Astro transfer buffer");
    this.sourceLength = utf8Length(this.source);
    let firstNonAscii = 0;
    while (firstNonAscii < this.source.length && this.source.charCodeAt(firstNonAscii) < 128)
      firstNonAscii++;
    this.firstNonAscii = firstNonAscii;
    this.poolOffset = 12 + layout.HEADER_SIZE + header[0] * layout.NODE_SIZE + header[1] * 4;
    this.commentOffset = this.poolOffset + Math.ceil(header[2] / 4) * 4;
    this.tokenOffset = this.commentOffset + header[4] * layout.COMMENT_SIZE;
    this.tokenWords = words(
      this.view.buffer,
      this.tokenOffset,
      header[5] * (layout.TOKEN_SIZE / 4),
      littleEndian,
    );
    this.cursor = treeEnd;
    return header;
  }
  firstTokenStart(start: number, end: number) {
    const tokens = this.tokenWords;
    for (let base = 0; base < tokens.length; base += layout.TOKEN_SIZE / 4) {
      const tokenStart = tokens[base + layout.TOKEN_START_U32];
      if (
        tokenStart >= start &&
        tokens[base + layout.TOKEN_END_U32] <= end &&
        tokens[base + layout.TOKEN_TAG_U32] !== layout.TOKEN_EOF_TAG
      )
        return tokenStart;
    }
    return end;
  }
  // Yuku transfers UTF-16 positions; Astro document metadata keeps UTF-8 byte offsets.
  byteOffset(unit: number) {
    return unit <= this.firstNonAscii ? unit : utf8Length(this.source.slice(0, unit));
  }
  yukuDiagnostic() {
    const severity = severities[this.u8()];
    const span = { start: this.u32(), end: this.u32() };
    const message = this.text(),
      help = this.u8() ? this.text() : null;
    const labels = new Array(this.u32());
    for (let i = 0; i < labels.length; i++) {
      labels[i] = { span: { start: this.u32(), end: this.u32() }, message: this.text() };
    }
    return { severity, message, span, help, labels };
  }
}
export default function decode(
  r: Reader,
  littleEndian = nativeLittleEndian,
): import("./types.ts").InternalParseResult {
  const { view } = r;
  const buffer = view.buffer;
  const h = r.open(littleEndian);
  const treeEnd = r.cursor;
  const [
    nodeCount,
    extraCount,
    poolLength,
    yukuSourceLength,
    commentCount,
    _tokenCount,
    diagnosticCount,
    root,
  ] = h;
  const sourceLength = r.sourceLength;
  let offset = 12 + layout.HEADER_SIZE;
  const nodes = [] as any[];
  offset += nodeCount * layout.NODE_SIZE;
  const extras: number[] = [];
  offset += extraCount * 4;
  const pool = r.buffer.subarray(offset, offset + poolLength);
  const strings = { extra: [] as number[] };
  offset += Math.ceil(poolLength / 4) * 4;
  const comments = new Array(commentCount);
  for (let i = 0; i < commentCount; i++, offset += layout.COMMENT_SIZE) {
    comments[i] = {
      type: view.getUint8(offset + layout.COMMENT_FLAGS_OFFSET) & 1 ? "block" : "line",
      position: commentPositions[(view.getUint8(offset + layout.COMMENT_FLAGS_OFFSET) >> 1) & 3],
      same_line: !!(view.getUint8(offset + layout.COMMENT_FLAGS_OFFSET) & 8),
      value: {
        start: view.getUint32(offset + layout.COMMENT_VALUE_START_OFFSET, littleEndian),
        end: view.getUint32(offset + layout.COMMENT_VALUE_END_OFFSET, littleEndian),
      },
      span: {
        start: view.getUint32(offset + layout.COMMENT_SPAN_START_OFFSET, littleEndian),
        end: view.getUint32(offset + layout.COMMENT_SPAN_END_OFFSET, littleEndian),
      },
    };
  }
  r.cursor = r.tokenOffset + r.tokenWords.byteLength;
  const diagnostics = new Array(diagnosticCount);
  for (let i = 0; i < diagnosticCount; i++) diagnostics[i] = r.yukuDiagnostic();
  if (r.cursor !== treeEnd) throw new Error("Invalid Yuku transfer size");
  const tree = {
    root,
    nodes,
    extras,
    source: r.source,
    strings,
    source_type: "module" as const,
    lang: "tsx" as const,
    comments,
    tokens: [],
    diagnostics,
    markup: [] as any[],
  };
  const templateStart = r.u32();
  let frontmatter: any = null;
  if (r.u8()) {
    const start = r.u32(),
      end = r.u32(),
      root = r.u32();
    frontmatter = { start, end, source: r.slice(start, end), root };
  }
  const astroNodes = new Array(r.u32());
  const nodesEnd = treeEnd + r.u32();
  r.cursor += astroNodes.length * 8;
  for (let i = 0; i < astroNodes.length; i++) {
    const node: any = schema.astroNode(r);
    node.javascript = r.root();
    node.typeArguments = r.root();
    astroNodes[i] = node;
  }
  if (r.cursor !== nodesEnd) throw new Error("Invalid Astro node section size");
  r.skipIntegers(); // Failed-node IDs are indexed for the direct public decoder.
  const rootIds = r.integers(),
    astComments = new Array(r.u32());
  for (let i = 0; i < astComments.length; i++) {
    astComments[i] = {
      type: r.string(),
      span: { start: r.u32(), end: r.u32() },
      value: r.string(),
    };
  }
  const astroDiagnostics = r.array(schema.diagnostic);
  tree.markup = new Array(r.u32());
  for (let i = 0; i < tree.markup.length; i++)
    tree.markup[i] = { node: r.u32(), astro_node: r.u32() };
  if (r.cursor !== buffer.byteLength) throw new Error("Invalid Astro transfer size");
  for (const comment of comments) {
    const { start, end } = comment.value;
    const value =
      start < yukuSourceLength
        ? r.source.slice(start, end)
        : decodeUtf8(pool.subarray(start - yukuSourceLength, end - yukuSourceLength));
    astComments.push({
      type: comment.type,
      span: { start: r.byteOffset(comment.span.start), end: r.byteOffset(comment.span.end) },
      value,
    });
  }
  astComments.sort((a, b) => a.span.start - b.span.start);
  let count = 0;
  for (const comment of astComments) {
    const previous = astComments[count - 1];
    if (
      previous &&
      previous.span.start === comment.span.start &&
      previous.span.end === comment.span.end
    )
      continue;
    astComments[count++] = comment;
  }
  astComments.length = count;
  return {
    ast: {
      type: "AstroRoot",
      start: 0,
      end: sourceLength,
      tree,
      frontmatter,
      template: {
        start: templateStart,
        end: sourceLength,
        source: r.slice(templateStart, sourceLength),
        nodes: astroNodes,
        rootIds,
      },
      comments: astComments,
    },
    diagnostics: astroDiagnostics,
  };
}

/** Inspect the original Yuku records in internal transfer tests. Not exported by the package. */
export function decodeSnapshot(
  buffer: ArrayBuffer,
  source: string,
  littleEndian = nativeLittleEndian,
) {
  const reader = new Reader(buffer, source);
  const result = decode(reader, littleEndian);
  const h = words(buffer, 12, layout.HEADER_SIZE / 4, littleEndian);
  const nodeCount = h[0],
    extraCount = h[1],
    poolLength = h[2];
  const view = new DataView(buffer);
  let offset = 12 + layout.HEADER_SIZE;
  const stride = layout.NODE_SIZE / 4;
  const nodeWords = words(buffer, offset, nodeCount * stride, littleEndian),
    nodes = new Array(nodeCount);
  for (let i = 0; i < nodes.length; i++) {
    const base = i * stride,
      byte = offset + i * layout.NODE_SIZE;
    nodes[i] = {
      data: schema.node(
        view.getUint8(byte),
        nodeWords,
        base,
        view.getUint16(byte + layout.NODE_FLAGS_OFFSET, littleEndian),
      ),
      span: {
        start: nodeWords[base + layout.NODE_SPAN_START_U32],
        end: nodeWords[base + layout.NODE_SPAN_END_U32],
      },
    };
  }
  result.ast.tree.nodes = nodes;
  offset += nodeCount * layout.NODE_SIZE;
  result.ast.tree.extras = integers(words(buffer, offset, extraCount, littleEndian));
  offset += extraCount * 4;
  result.ast.tree.strings.extra = integers(new Uint8Array(buffer, offset, poolLength));
  const tokenWords = reader.tokenWords;
  const tokenStride = layout.TOKEN_SIZE / 4;
  const tokens = new Array(tokenWords.length / tokenStride);
  for (let i = 0; i < tokens.length; i++) {
    const base = i * tokenStride;
    const flagsOffset = reader.tokenOffset + i * layout.TOKEN_SIZE + layout.TOKEN_FLAGS_U32 * 4;
    tokens[i] = {
      tag: schema.tokenTags[tokenWords[base + layout.TOKEN_TAG_U32]],
      span: {
        start: tokenWords[base + layout.TOKEN_START_U32],
        end: tokenWords[base + layout.TOKEN_END_U32],
      },
      flags: view.getUint8(flagsOffset),
      _pad: [
        view.getUint8(flagsOffset + 1),
        view.getUint8(flagsOffset + 2),
        view.getUint8(flagsOffset + 3),
      ],
    };
  }
  result.ast.tree.tokens = tokens;
  return result;
}
