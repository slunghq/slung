export type WireEvent = {
  timestamp: number;
  value: number;
  series: string;
  tags: string[];
};

const HEADER_BYTES = 8 + 8 + 2 + 2;
const MAX_U16 = 0xffff;

function toUtf8(input: string, label: string): Buffer {
  const buf = Buffer.from(input, "utf8");
  if (buf.length > MAX_U16) {
    throw new Error(`${label} exceeds ${MAX_U16} bytes`);
  }
  return buf;
}

function encodeFromBuffers(
  timestamp: number,
  value: number,
  seriesBuf: Buffer,
  tagBufs: Buffer[],
): Buffer {
  if (tagBufs.length > MAX_U16) {
    throw new Error(`tag count exceeds ${MAX_U16}`);
  }

  let total = HEADER_BYTES + seriesBuf.length;
  for (const tag of tagBufs) total += 2 + tag.length;

  const out = Buffer.allocUnsafe(total);
  let offset = 0;
  out.writeBigInt64LE(BigInt(Math.trunc(timestamp)), offset);
  offset += 8;
  out.writeDoubleLE(value, offset);
  offset += 8;
  out.writeUInt16LE(seriesBuf.length, offset);
  offset += 2;
  out.writeUInt16LE(tagBufs.length, offset);
  offset += 2;
  seriesBuf.copy(out, offset);
  offset += seriesBuf.length;

  for (const tag of tagBufs) {
    out.writeUInt16LE(tag.length, offset);
    offset += 2;
    tag.copy(out, offset);
    offset += tag.length;
  }

  return out;
}

export function createEventBinaryEncoder(
  series: string,
  tags: string[],
): (timestamp: number, value: number) => Buffer {
  const seriesBuf = toUtf8(series, "series");
  const tagBufs = tags.map((tag) => toUtf8(tag, "tag"));
  return (timestamp: number, value: number) =>
    encodeFromBuffers(timestamp, value, seriesBuf, tagBufs);
}

export function encodeEventBinary(event: WireEvent): Buffer {
  const seriesBuf = toUtf8(event.series, "series");
  const tagBufs = event.tags.map((tag) => toUtf8(tag, "tag"));
  return encodeFromBuffers(event.timestamp, event.value, seriesBuf, tagBufs);
}

export function decodeEventBinary(buf: Buffer): WireEvent | null {
  if (buf.length < HEADER_BYTES) return null;

  let offset = 0;
  const timestamp = Number(buf.readBigInt64LE(offset));
  offset += 8;
  const value = buf.readDoubleLE(offset);
  offset += 8;
  const seriesLen = buf.readUInt16LE(offset);
  offset += 2;
  const tagCount = buf.readUInt16LE(offset);
  offset += 2;

  if (offset + seriesLen > buf.length) return null;
  const series = buf.toString("utf8", offset, offset + seriesLen);
  offset += seriesLen;

  const tags: string[] = [];
  for (let i = 0; i < tagCount; i += 1) {
    if (offset + 2 > buf.length) return null;
    const tagLen = buf.readUInt16LE(offset);
    offset += 2;
    if (offset + tagLen > buf.length) return null;
    tags.push(buf.toString("utf8", offset, offset + tagLen));
    offset += tagLen;
  }

  if (offset !== buf.length) return null;
  return { timestamp, value, series, tags };
}
