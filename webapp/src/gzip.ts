/** GZIP via web-native CompressionStream/DecompressionStream (browser + Node >= 18). */

async function pipe(data: Uint8Array, stream: CompressionStream | DecompressionStream): Promise<Uint8Array> {
  const out = new Blob([data as BlobPart]).stream().pipeThrough(stream);
  return new Uint8Array(await new Response(out).arrayBuffer());
}

export function gzipCompress(data: Uint8Array): Promise<Uint8Array> {
  return pipe(data, new CompressionStream('gzip'));
}

export function gzipDecompress(data: Uint8Array): Promise<Uint8Array> {
  return pipe(data, new DecompressionStream('gzip'));
}

export function isGzip(data: Uint8Array): boolean {
  return data.length >= 2 && data[0] === 0x1f && data[1] === 0x8b;
}
