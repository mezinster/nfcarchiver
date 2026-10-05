/**
 * Which bytes the Archive button would write. Pure, so the mode rule is unit
 * tested: in Text mode a previously chosen file is ignored (its input is
 * hidden), and in File mode typed text is ignored.
 */
export type SourceMode = 'file' | 'text';
export interface Source { data: Uint8Array; fileName: string }
export const TEXT_FILE_NAME = 'text_note.txt';

export function pickSource(
  mode: SourceMode,
  file: { bytes: Uint8Array; name: string } | null,
  text: string,
): Source | null {
  if (mode === 'file') return file ? { data: file.bytes, fileName: file.name } : null;
  return text.length > 0 ? { data: new TextEncoder().encode(text), fileName: TEXT_FILE_NAME } : null;
}
