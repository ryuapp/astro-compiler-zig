import type { TransformResult } from "./types.ts";
import { decodeBase64, decodeUtf8, encodeBase64 } from "./encoding.ts";

const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
type Edit = { start: number; end: number; value: string };

function encode(delta: number) {
  let value = Math.abs(delta) * 2 + (delta < 0 ? 1 : 0);
  let output = "";
  do {
    const digit = value % 32;
    value = Math.floor(value / 32);
    output += alphabet[digit + (value ? 32 : 0)];
  } while (value);
  return output;
}

// Only the first VLQ field changes: generated columns move, while source,
// original line/column and optional name deltas remain untouched.
function shiftMappings(mappings: string, edits: Map<number, Edit[]>) {
  return mappings
    .split(";")
    .map((line, index) => {
      const changes = edits.get(index);
      if (!changes || !line) return line;
      let previous = 0;
      let previousShifted = 0;
      return line
        .split(",")
        .map((segment) => {
          let value = 0;
          let factor = 1;
          let end = 0;
          let digit: number;
          do {
            digit = alphabet.indexOf(segment[end++]);
            value += (digit & 31) * factor;
            factor *= 32;
          } while (digit & 32);
          previous += value % 2 ? -Math.floor(value / 2) : value / 2;
          let shift = 0;
          let column = previous;
          for (const edit of changes) {
            if (previous < edit.start) break;
            if (previous < edit.end) {
              column = edit.start + Math.min(previous - edit.start, edit.value.length);
              break;
            }
            shift += edit.value.length - (edit.end - edit.start);
          }
          const shifted = column + shift;
          const first = encode(shifted - previousShifted);
          previousShifted = shifted;
          return first + segment.slice(end);
        })
        .join(",");
    })
    .join(";");
}

/** Apply path replacements and keep external and inline maps in sync. */
export function replaceComponentPaths(
  result: Pick<TransformResult, "code" | "map">,
  replacements: Map<string, string>,
) {
  if (!replacements.size) return;
  const marker = "\n//# sourceMappingURL=data:application/json;base64,";
  const inlineMap =
    /\n\/\/# sourceMappingURL=data:application\/json;base64,([A-Za-z0-9+/=]+)$/u.exec(result.code);
  const inline = inlineMap?.index ?? -1;
  const code = inline < 0 ? result.code : result.code.slice(0, inline);
  const edits: Edit[] = [];
  for (const [from, value] of replacements) {
    let start = code.indexOf(from);
    while (start >= 0) {
      edits.push({ start, end: start + from.length, value });
      start = code.indexOf(from, start + from.length);
    }
  }
  if (!edits.length) return;
  edits.sort((a, b) => a.start - b.start);
  const lines = new Map<number, Edit[]>();
  const starts = [0];
  for (const match of code.matchAll(/\r\n|[\r\n\u2028\u2029]/gu))
    starts.push(match.index + match[0].length);
  let line = 0;
  let cursor = 0;
  let output = "";
  for (const edit of edits) {
    output += code.slice(cursor, edit.start) + edit.value;
    cursor = edit.end;
    while (line + 1 < starts.length && starts[line + 1] <= edit.start) line++;
    const changes = lines.get(line) ?? [];
    changes.push({
      start: edit.start - starts[line],
      end: edit.end - starts[line],
      value: edit.value,
    });
    lines.set(line, changes);
  }
  output += code.slice(cursor);
  const encoded = result.map || (inline < 0 ? "" : decodeUtf8(decodeBase64(inlineMap![1])));
  if (encoded) {
    const map = JSON.parse(encoded);
    map.mappings = shiftMappings(map.mappings, lines);
    const updated = JSON.stringify(map);
    if (result.map) result.map = updated;
    if (inline >= 0) output += marker + encodeBase64(updated);
  }
  result.code = output;
}
