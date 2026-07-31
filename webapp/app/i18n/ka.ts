/** Georgian catalogue. Shared terms seeded from lib/l10n/app_ka.arb. */
import type { Messages } from './en.js';
import { pr } from './plural.js';

// Georgian nouns take no plural marker after a numeral ("5 ბარათი"), so both
// categories are the same word. `other` is still required by PluralForms.
const CARD = { one: 'ბარათი', other: 'ბარათი' };
const FILE = { one: 'ფაილი', other: 'ფაილი' };

export const ka: Messages = {
  // — shell / device bar —
  connect: 'Chameleon-თან დაკავშირება',
  usePhoneNfc: 'ტელეფონის NFC-ის გამოყენება',
  disconnect: 'გათიშვა',
  inspectCard: 'ბარათის დათვალიერება',
  themeToggle: 'ღია/მუქი თემა',
  language: 'ენა',
  statusConnected: 'დაკავშირებულია',
  statusDisconnected: 'გათიშულია',
  connectedDot: 'დაკავშირებულია.',
  connectedPhoneNfc: 'გამოიყენება ტელეფონის NFC.',
  readerDisconnectedClickConnect: 'წამკითხველი გაითიშა — გასაგრძელებლად დააჭირეთ „დაკავშირებას“.',
  inspectNeedsChameleon: 'ბარათის დათვალიერებას სჭირდება Chameleon — ტელეფონის NFC-ს არ აქვს პირდაპირი წვდომა ბარათთან.',
  autoDetectNeedsChameleon: 'აირჩიეთ ბარათის ტიპი: ტელეფონის NFC ვერ ამოიცნობს ბარათის ტევადობას.',

  // — tabs —
  tabArchive: 'არქივაცია',
  tabRestore: 'აღდგენა',
  tabFiles: 'ფაილები',
  tabLog: 'ჟურნალი',
  tabAbout: 'შესახებ',

  // — archive tab —
  orText: 'ან ტექსტი:',
  textPlaceholder: 'აკრიფეთ ტექსტი text_note.txt-ად დასაარქივებლად',
  targetTag: 'სამიზნე ტეგი',
  targetAuto: 'ავტომატური ამოცნობა (მოერგება ბარათს)',
  compress: 'შეკუმშვა',
  password: 'პაროლი',
  optionalPlaceholder: '(არასავალდებულო)',
  archiveToCards: 'ბარათებზე დაარქივება',
  archiveIdle: 'დააკავშირეთ Chameleon, შემდეგ აირჩიეთ ფაილი ან აკრიფეთ ტექსტი.',
  archiveReady: 'აირჩიეთ ფაილი ან აკრიფეთ ტექსტი, შემდეგ დააჭირეთ „ბარათებზე დაარქივებას“.',
  archivePickFirst: 'ჯერ აირჩიეთ ფაილი ან აკრიფეთ ტექსტი.',
  cardEstimate: (n, isAuto) =>
    `≈ ${n} ${pr(n, CARD)}${isAuto ? ' (სავარაუდო) — მოერგება მიდებულ ბარათს' : ''}`,

  // — archive write loop —
  progressDone: (written, total) => `✓ ჩაწერილი და შემოწმებულია ${written} ბარათი ${total}-დან`,
  progressWriting: (written, total) =>
    `✓ ჩაწერილი და შემოწმებულია ${written} / ${total} — მიადეთ შემდეგი ბარათი`,
  archiveDone: (n) => `დასრულდა — ჩაწერილი და შემოწმებულია ${n} ${pr(n, CARD)}.`,
  tapCardOf: (i, total) => `მიადეთ ბარათი ${i} / ${total} წამკითხველს…`,
  readerDisconnectedResume: 'წამკითხველი გაითიშა — გასაგრძელებლად ხელახლა დააკავშირეთ.',
  readerSwitchedResume: 'წამკითხველი შეიცვალა — გრძელდება ახალ წამკითხველზე.',
  rechunked: (payloadSize, total) =>
    `ბარათზე ეტევა ${payloadSize} B/chunk — ამის ნაცვლად ჩაიწერება ${total} ${pr(total, CARD)}.`,
  noCardTapHold: 'ბარათი ვერ მოიძებნა — მიადეთ ბარათი (დაიჭირეთ რამდენიმე მმ-ით მოშორებით)…',
  unsupportedTapOther: 'ტეგი მხარდაუჭერელია — მიადეთ Mifare Classic 1K ან NTAG.',
  skippedTapDifferent: 'გამოტოვებულია. მიადეთ სხვა ბარათი…',
  retryAfter: (message) => `${message} — გასამეორებლად მიადეთ ხელახლა.`,

  // — overwrite dialog —
  overwrite: 'გადაწერა',
  overwriteAll: 'ყველა დარჩენილის გადაწერა',
  skip: 'გამოტოვება',

  // — restore tab —
  scanCards: 'ბარათების სკანირება',
  stop: 'გაჩერება',
  saveAs: 'შენახვა როგორც',
  restoreIdle: 'დააკავშირეთ Chameleon, შემდეგ დაასკანირეთ ბარათების დასტა.',
  restoreReady: 'დაასკანირეთ ბარათების დასტა არქივების აღმოსაჩენად.',
  scanning: 'სკანირება — მიადეთ ბარათები წამკითხველს…',
  tapMoreCards: 'მიადეთ კიდევ ბარათები ან აღადგინეთ დასრულებული არქივი.',
  skippedCard: (message) => `ბარათი გამოტოვდა: ${message}`,
  restore: 'აღდგენა',
  archiveRow: (shortId, isEncrypted, received, total, complete) =>
    `არქივი ${shortId}…  ${isEncrypted ? '🔒 დაშიფრული' : 'დაუშიფრავი'}  ·  ${received} / ${total} ${pr(total, CARD)}${complete ? ' ✓' : ''}`,
  restoredBytes: (bytes, name) => `აღდგენილია ${bytes} ბაიტი → ${name}.`,

  // — passwords —
  promptArchiveEncrypted: 'ეს არქივი დაშიფრულია. შეიყვანეთ პაროლი:',
  promptFileEncrypted: 'ეს ფაილი დაშიფრულია. შეიყვანეთ პაროლი:',
  promptWrongPassword: 'არასწორი პაროლი. შეიყვანეთ პაროლი:',
  tooManyPasswordAttempts: 'პაროლის შეყვანის ძალიან ბევრი წარუმატებელი მცდელობა.',
  cancelled: 'გაუქმებულია.',

  // — files tab —
  filesEmpty: 'აღდგენილი ფაილები ჯერ არ არის. აღადგინეთ არქივი და ის აქ გამოჩნდება.',
  clearAll: 'ყველას გასუფთავება',
  confirmClearAll: 'წაიშალოს ყველა შენახული ფაილი? ეს მოქმედება შეუქცევადია.',
  download: 'ჩამოტვირთვა',
  deleteBtn: 'წაშლა',
  filesInfo: (count, size) => `${count} ${pr(count, FILE)} · შენახულია ${size}`,
  clearedFiles: (n) => `წაიშალა ${n} ${pr(n, FILE)}.`,
  downloadedTo: (size, name) => `ჩამოიტვირთა ${size} → ${name}.`,
  fileRow: (name, size, when, isEncrypted, totalChunks) =>
    `${name}  ·  ${size}  ·  ${when}  ·  ${isEncrypted ? '🔒 დაშიფრული' : 'დაუშიფრავი'}  ·  ${totalChunks} ${pr(totalChunks, CARD)}`,

  // — log tab (controls only; log ENTRIES stay English) —
  logLevel: 'დონე',
  autoScroll: 'ავტოგადახვევა',
  mirrorToConsole: 'კონსოლში დუბლირება',
  clear: 'გასუფთავება',
  copy: 'კოპირება',

  // — inspect dialog —
  close: 'დახურვა',
  inspectIdentity: 'იდენტიფიკაცია',
  inspectNfar: 'NFAR ნაწილი',
  inspectRaw: 'ნედლი მონაცემები',
  inspectHoldStill: 'უძრავად დაიჭირეთ ბარათი წამკითხველზე…',
  inspectReading: (done, total) => `იკითხება… ${done}/${total}`,
  inspectRead: (done, total) => `წაკითხულია ${done}/${total}`,
  inspectStopped: 'შეჩერებულია.',
  inspectCardLost: 'ბარათმა დატოვა ველი — მიადეთ ხელახლა და თავიდან დაათვალიერეთ.',
  inspectDone: 'დასრულდა.',

  // — about tab —
  aboutWebVersion: (version, sha) => `ვებ-ვერსია ${version} (${sha})`,
  aboutDescription: 'განაწილებული მონაცემთა არქივაციის სისტემა NFC ტეგების გამოყენებით. შეინახეთ ფაილები რამდენიმე ტეგზე და აღადგინეთ ისინი მოგვიანებით — სრულიად თქვენს ბრაუზერში.',
  aboutSupportedHeading: 'მხარდაჭერილი ტეგები',
  aboutSupportedBody: 'Mifare Classic 1K და NTAG213/215/216 — Chameleon Ultra-ს საშუალებით, Web Bluetooth-ით.',
  aboutWebNfcNote: '(NTAG-ის ჩაწერა ტელეფონის საკუთარი NFC-ით — Chameleon-ის გარეშე — მომავალ Web NFC მხარდაჭერასთან ერთად გამოჩნდება.)',
  aboutPrivacyHeading: 'კონფიდენციალურობა',
  aboutPrivacyBody: 'ყველაფერი მუშაობს კლიენტის მხარეს. თქვენი ფაილები, ტექსტი და პაროლები არასოდეს ტოვებს ბრაუზერს — არ არსებობს არც სერვერი, არც ატვირთვა და არც თვალყურის დევნება.',
  aboutLicensesHeading: 'ღია კოდის ლიცენზიები',
  aboutLicenseApp: 'NFC Archiver — MIT License © 2026 mezinster.',
  aboutLicenseSdk: 'chameleon-ultra.js — MIT License.',

  // — errors (the humanError seam) —
  errCardAuth: 'ბარათის გასაღებები ქარხნული არ არის — ამ ბარათის გამოყენება შეუძლებელია.',
  errCardRead: 'ბარათი ბოლომდე ვერ წაიკითხა — უძრავად დაიჭირეთ წამკითხველზე და მიადეთ ხელახლა.',
  errWriteVerify: 'ჩაწერის შემოწმება ვერ მოხერხდა — მიაახლოვეთ ბარათი და სცადეთ ხელახლა.',
  errCardCapacity: 'ეს ბარათი უკვე ჩაწერილებზე პატარაა — გამოიყენეთ ერთი ტიპის ბარათები ან თავიდან დაიწყეთ არქივაცია.',
  errTagTimeout: 'ბარათი ვერ მოიძებნა — მიადეთ ბარათი წამკითხველს.',
  errNfarFormat: 'ამ ბარათზე NFAR არქივის მონაცემები არ არის.',
  errOverwriteRequired: 'ამ ბარათზე უკვე არის მონაცემები.',
  errPasswordRequired: 'ეს არქივი დაშიფრულია — შეიყვანეთ პაროლი.',
  errWrongPassword: 'არასწორი პაროლი.',
  errUnsupportedTag: 'ტეგი მხარდაუჭერელია — გამოიყენეთ Mifare Classic 1K ან NTAG213/215/216.',
  errUnidentifiedTag: 'ბარათმა იდენტიფიკატორი არ გადმოსცა — მოაშორეთ და ხელახლა მიადეთ.',
  errNdefFormat: 'ამ ტეგზე NFAR NDEF მონაცემები არ არის.',
};
