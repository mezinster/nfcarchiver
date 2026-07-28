/** Formats a 16-byte archive ID as an 8-4-4-4-12 UUID string (matches the Flutter app). */
export function formatArchiveId(id: Uint8Array): string {
  const hex = Array.from(id, (b) => b.toString(16).padStart(2, '0')).join('');
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}
