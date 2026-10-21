// Adapted from Yuku's packages/yuku/core/decode.js buildPosMap (MIT),
// copyright (c) 2026 Yuku. See LICENSE. Keep interior bytes at the code point's start.
function byteIndex(source: string, byteLength: number, startByte: number) {
  const result = new Uint32Array(byteLength - startByte + 1);
  let byte = 0,
    index = startByte;
  while (index < source.length) {
    if (index + 16 <= source.length) {
      let ascii = true;
      for (let offset = 0; offset < 16; offset++) {
        if (source.charCodeAt(index + offset) >= 0x80) {
          ascii = false;
          break;
        }
      }
      if (ascii) {
        for (let offset = 0; offset < 16; offset++) result[byte + offset] = index + offset;
        byte += 16;
        index += 16;
        continue;
      }
    }
    const unit = source.charCodeAt(index);
    if (unit < 0x80) {
      result[byte++] = index++;
      continue;
    }
    const pair =
      unit >= 0xd800 && unit < 0xdc00 && (source.charCodeAt(index + 1) & 0xfc00) === 0xdc00;
    const length = unit < 0x800 ? 2 : pair ? 4 : 3;
    for (let offset = 0; offset < length; offset++) result[byte + offset] = index;
    byte += length;
    index += pair ? 2 : 1;
  }
  result[byte] = index;
  return result;
}
export { byteIndex };
