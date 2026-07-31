/**
 * The English catalogue, and the schema every other locale is checked against.
 *
 * Deliberately NOT `as const`: literal types here would force every translation
 * to repeat the English string verbatim to satisfy `: Messages`.
 *
 * Entries are functions wherever a value is interpolated, so each locale
 * controls its own word order.
 */
import { pr } from './plural.js';

export const en = {
  // — shell / device bar —
  connect: 'Connect Chameleon',
  usePhoneNfc: 'Use phone NFC',
  disconnect: 'Disconnect',
  inspectCard: 'Inspect card',
  themeToggle: 'Toggle light/dark',
  language: 'Language',
  statusConnected: 'connected',
  statusDisconnected: 'disconnected',
  connectedDot: 'Connected.',
  connectedPhoneNfc: 'Using phone NFC.',
  readerDisconnectedClickConnect: 'Reader disconnected — click Connect to resume.',
  inspectNeedsChameleon: 'Card inspection needs a Chameleon — phone NFC has no raw card access.',
  readerBusyElsewhere: 'The reader is busy with another operation — finish or stop it first.',
  autoDetectNeedsChameleon: 'Pick a tag type: phone NFC cannot detect card capacity.',

  // — tabs —
  tabArchive: 'Archive',
  tabRestore: 'Restore',
  tabFiles: 'Files',
  tabLog: 'Log',
  tabAbout: 'About',

  // — archive tab —
  orText: 'or text:',
  textPlaceholder: 'Type text to archive as text_note.txt',
  targetTag: 'target tag',
  targetAuto: 'Auto-detect (adapts to the card)',
  compress: 'compress',
  password: 'password',
  optionalPlaceholder: '(optional)',
  archiveToCards: 'Archive to cards',
  archiveIdle: 'Connect a Chameleon, then choose a file or type text.',
  archiveReady: 'Choose a file or type text, then Archive to cards.',
  archivePickFirst: 'Pick a file or type some text first.',
  cardEstimate: (n: number, isAuto: boolean) =>
    `≈ ${n} ${pr(n, { one: 'card', other: 'cards' })}${isAuto ? ' (est.) — adapts to the tapped card' : ''}`,

  // — archive write loop —
  progressDone: (written: number, total: number) => `✓ ${written} of ${total} cards written & verified`,
  progressWriting: (written: number, total: number) => `✓ ${written} of ${total} written & verified — tap the next card`,
  archiveDone: (n: number) => `Done — wrote and verified ${n} ${pr(n, { one: 'card', other: 'cards' })}.`,
  tapCardOf: (i: number, total: number) => `Tap card ${i} of ${total} on the reader…`,
  readerDisconnectedResume: 'Reader disconnected — reconnect to resume.',
  readerSwitchedResume: 'Reader switched — resuming on the new reader.',
  rechunked: (payloadSize: number, total: number) =>
    `Card holds ${payloadSize} B/chunk — writing ${total} ${pr(total, { one: 'card', other: 'cards' })} instead.`,
  noCardTapHold: 'No card detected — tap a card (hold it a few mm off)…',
  unsupportedTapOther: 'Unsupported tag — tap a Mifare Classic 1K or NTAG.',
  skippedTapDifferent: 'Skipped. Tap a different card…',
  retryAfter: (message: string) => `${message} — re-tap to retry.`,
  scanGaveUp: (message: string) => `Stopped after repeated failures: ${message}`,

  // — overwrite dialog —
  overwrite: 'Overwrite',
  overwriteAll: 'Overwrite all remaining',
  skip: 'Skip',

  // — restore tab —
  scanCards: 'Scan cards',
  stop: 'Stop',
  saveAs: 'save as',
  restoreIdle: 'Connect a Chameleon, then scan a pile of cards.',
  restoreReady: 'Scan a pile of cards to detect archives.',
  scanning: 'Scanning — tap cards on the reader…',
  tapMoreCards: 'Tap more cards, or Restore a complete one.',
  skippedCard: (message: string) => `Skipped a card: ${message}`,
  restore: 'Restore',
  archiveRow: (shortId: string, isEncrypted: boolean, received: number, total: number, complete: boolean) =>
    `Archive ${shortId}…  ${isEncrypted ? '🔒 encrypted' : 'unencrypted'}  ·  ${received} / ${total} ${pr(total, { one: 'card', other: 'cards' })}${complete ? ' ✓' : ''}`,
  restoredBytes: (bytes: number, name: string) => `Restored ${bytes} bytes → ${name}.`,

  // — passwords —
  promptArchiveEncrypted: 'This archive is encrypted. Enter password:',
  promptFileEncrypted: 'This file is encrypted. Enter password:',
  promptWrongPassword: 'Wrong password. Enter password:',
  tooManyPasswordAttempts: 'Too many failed password attempts.',
  cancelled: 'Cancelled.',

  // — files tab —
  filesEmpty: "No restored files yet. Restore an archive and it'll appear here.",
  clearAll: 'Clear all',
  confirmClearAll: 'Delete all stored files? This cannot be undone.',
  download: 'Download',
  deleteBtn: 'Delete',
  filesInfo: (count: number, size: string) =>
    `${count} ${pr(count, { one: 'file', other: 'files' })} · ${size} stored`,
  clearedFiles: (n: number) => `Cleared ${n} ${pr(n, { one: 'file', other: 'files' })}.`,
  downloadedTo: (size: string, name: string) => `Downloaded ${size} → ${name}.`,
  fileRow: (name: string, size: string, when: string, isEncrypted: boolean, totalChunks: number) =>
    `${name}  ·  ${size}  ·  ${when}  ·  ${isEncrypted ? '🔒 encrypted' : 'plain'}  ·  ${totalChunks} ${pr(totalChunks, { one: 'card', other: 'cards' })}`,

  // — log tab (controls only; log ENTRIES stay English) —
  logLevel: 'level',
  autoScroll: 'auto-scroll',
  mirrorToConsole: 'mirror to console',
  clear: 'Clear',
  copy: 'Copy',

  // — inspect dialog —
  close: 'Close',
  inspectIdentity: 'Identity',
  inspectNfar: 'NFAR chunk',
  inspectRaw: 'Raw',
  inspectHoldStill: 'Hold the card still on the reader…',
  inspectReading: (done: number, total: number) => `reading… ${done}/${total}`,
  inspectRead: (done: number, total: number) => `${done}/${total} read`,
  inspectStopped: 'Stopped.',
  inspectCardLost: 'Card left the field — re-tap and inspect again.',
  inspectDone: 'Done.',

  // — about tab —
  aboutWebVersion: (version: string, sha: string) => `Web version ${version} (${sha})`,
  aboutDescription: 'A distributed data archive system using NFC tags. Store files across multiple tags and restore them later — fully in your browser.',
  aboutSupportedHeading: 'Supported tags',
  aboutSupportedBody: 'Mifare Classic 1K and NTAG213/215/216, via a Chameleon Ultra over Web Bluetooth.',
  aboutWebNfcNote: '(Writing NTAG with the phone’s own NFC — no Chameleon — will come with the future Web NFC support.)',
  aboutPrivacyHeading: 'Privacy',
  aboutPrivacyBody: 'Everything runs client-side. Your files, text, and passwords never leave the browser — there is no server, no upload, and no tracking.',
  aboutLicensesHeading: 'Open-source licenses',
  aboutLicenseApp: 'NFC Archiver — MIT License © 2026 mezinster.',
  aboutLicenseSdk: 'chameleon-ultra.js — MIT License.',

  // — errors (the humanError seam) —
  errCardAuth: 'Card keys are not factory defaults — this card cannot be used.',
  errCardRead: 'Card read was incomplete — hold the card steady on the reader and tap again.',
  errWriteVerify: 'Write verification failed — move the card closer and retry.',
  errCardCapacity: 'This card is smaller than the ones already written — use cards of the same type, or restart the archive.',
  errTagTimeout: 'No card detected — tap a card on the reader.',
  errNfarFormat: 'This card holds no NFAR archive data.',
  errOverwriteRequired: 'This card already holds data.',
  errPasswordRequired: 'This archive is encrypted — enter a password.',
  errWrongPassword: 'Wrong password.',
  errUnsupportedTag: 'Unsupported tag — use a Mifare Classic 1K or NTAG213/215/216.',
  errUnidentifiedTag: 'The card did not identify itself — lift it away and tap it again.',
  errNdefFormat: 'This tag holds no NFAR NDEF data.',
};

export type Messages = typeof en;
