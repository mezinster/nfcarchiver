/** Ukrainian catalogue. Shared terms seeded from lib/l10n/app_uk.arb. */
import type { Messages } from './en.js';
import { pr } from './plural.js';

const CARD = { one: 'картка', few: 'картки', many: 'карток', other: 'карток' };
const CARD_GEN = { one: 'картки', few: 'карток', many: 'карток', other: 'карток' };
// Accusative: the impersonal passive «записано» governs the accusative, not the
// nominative CARD table.
const CARD_ACC = { one: 'картку', few: 'картки', many: 'карток', other: 'карток' };
const FILE = { one: 'файл', few: 'файли', many: 'файлів', other: 'файлів' };
const BYTE = { one: 'байт', few: 'байти', many: 'байтів', other: 'байтів' };

export const uk: Messages = {
  // — shell / device bar —
  connect: 'Підключити Chameleon',
  usePhoneNfc: 'Використати NFC телефону',
  disconnect: 'Відключити',
  inspectCard: 'Оглянути картку',
  themeToggle: 'Світла/темна тема',
  language: 'Мова',
  statusConnected: 'підключено',
  statusDisconnected: 'відключено',
  readerChameleon: 'Chameleon Ultra.',
  readerPhoneNfc: 'NFC телефону.',
  readerDisconnectedClickConnect: 'Зчитувач відключено — натисніть «Підключити», щоб продовжити.',
  inspectNeedsChameleon: 'Для огляду картки потрібен Chameleon — NFC телефону не має прямого доступу до картки.',
  readerBusyElsewhere: 'Зчитувач зайнятий іншою операцією — спершу завершіть або зупиніть її.',
  sectionSource: 'Джерело',
  sectionSettings: 'Налаштування',
  sectionArchives: 'Знайдені архіви',
  sectionRestoredFiles: 'Відновлені файли',
  sectionLogOptions: 'Параметри журналу',
  subChooseFile: 'Будь-який файл, розділений по картках',
  subTypeText: 'Зберігається як text_note.txt',
  subTargetTag: 'Тип картки та ємність',
  subCompress: 'GZIP перед записом',
  subPassword: 'AES-256-GCM, необовʼязково',
  subSaveAs: 'Використовується, лише якщо в архіві немає імені файлу',
  autoDetectNeedsChameleon: 'Виберіть тип мітки: NFC телефону не може визначити ємність картки.',

  // — tabs —
  tabArchive: 'Архівувати',
  tabRestore: 'Відновити',
  tabFiles: 'Файли',
  tabLog: 'Журнал',
  tabAbout: 'Про програму',

  // — archive tab —
  sourceFile: 'Файл',
  sourceText: 'Текст',
  orSeparator: 'або',
  textPlaceholder: 'Введіть текст для архівації у text_note.txt',
  targetTag: 'тип мітки',
  targetAuto: 'Автовизначення (підлаштується під картку)',
  compress: 'стиснення',
  password: 'пароль',
  optionalPlaceholder: '(необов’язково)',
  archiveToCards: 'Архівувати на картки',
  archiveIdle: 'Підключіть Chameleon, потім виберіть файл або введіть текст.',
  archiveReady: 'Виберіть файл або введіть текст, потім натисніть «Архівувати на картки».',
  archivePickFirst: 'Спочатку виберіть файл або введіть текст.',
  cardEstimate: (n, isAuto) =>
    `≈ ${n} ${pr(n, CARD)}${isAuto ? ' (оцінка) — підлаштується під картку' : ''}`,

  // — archive write loop —
  progressDone: (written, total) => `✓ записано та перевірено ${written} з ${total} ${pr(total, CARD_GEN)}`,
  progressWriting: (written, total) =>
    `✓ записано та перевірено ${written} з ${total} — прикладіть наступну картку`,
  archiveDone: (n) => `Готово — записано та перевірено ${n} ${pr(n, CARD_ACC)}.`,
  tapCardOf: (i, total) => `Прикладіть картку ${i} з ${total} до зчитувача…`,
  writingCard: (i, total) => `Запис картки ${i} з ${total} — не прибирайте картку…`,
  cardAlreadyWritten: (uid) =>
    `На картку ${uid} вже записано частину цього архіву — прикладіть іншу картку (у клонів однаковий UID).`,
  awaitingOverwriteAnswer: 'На картці вже є дані — чекаємо на вашу відповідь у діалозі…',
  readerDisconnectedResume: 'Зчитувач відключено — підключіться знову, щоб продовжити.',
  readerSwitchedResume: 'Зчитувач змінено — продовжуємо на новому зчитувачі.',
  rechunked: (payloadSize, total) =>
    `На картку вміщується ${payloadSize} B/chunk — натомість ${total} ${pr(total, CARD)}.`,
  noCardTapHold: 'Картку не виявлено — прикладіть картку (тримайте за кілька мм від зчитувача)…',
  unsupportedTapOther: 'Мітка не підтримується — прикладіть Mifare Classic 1K або NTAG.',
  skippedTapDifferent: 'Пропущено. Прикладіть іншу картку…',
  retryAfter: (message) => `${message} — прикладіть знову, щоб повторити.`,
  scanGaveUp: (message) => `Зупинено через повторні помилки: ${message}`,

  // — overwrite dialog —
  overwrite: 'Перезаписати',
  overwriteAll: 'Перезаписати решту',
  skip: 'Пропустити',

  // — restore tab —
  scanCards: 'Сканувати картки',
  stop: 'Стоп',
  saveAs: 'зберегти як',
  restoreIdle: 'Підключіть Chameleon, потім відскануйте стос карток.',
  restoreReady: 'Відскануйте стос карток, щоб знайти архіви.',
  scanning: 'Сканування — прикладайте картки до зчитувача…',
  tapMoreCards: 'Прикладіть ще картки або відновіть готовий архів.',
  skippedCard: (message) => `Картку пропущено: ${message}`,
  restore: 'Відновити',
  archiveRow: (shortId, isEncrypted, received, total, complete) =>
    `Архів ${shortId}…  ${isEncrypted ? '🔒 зашифровано' : 'без шифрування'}  ·  ${received} / ${total} ${pr(total, CARD)}${complete ? ' ✓' : ''}`,
  restoredBytes: (bytes, name) => `Відновлено ${bytes} ${pr(bytes, BYTE)} → ${name}.`,

  // — passwords —
  promptArchiveEncrypted: 'Цей архів зашифровано. Введіть пароль:',
  promptFileEncrypted: 'Цей файл зашифровано. Введіть пароль:',
  promptWrongPassword: 'Неправильний пароль. Введіть пароль:',
  tooManyPasswordAttempts: 'Забагато невдалих спроб введення пароля.',
  cancelled: 'Скасовано.',

  // — files tab —
  filesEmpty: 'Відновлених файлів поки немає. Відновіть архів — і він з’явиться тут.',
  clearAll: 'Очистити все',
  confirmClearAll: 'Видалити всі збережені файли? Цю дію неможливо скасувати.',
  download: 'Завантажити',
  deleteBtn: 'Видалити',
  filesInfo: (count, size) => `${count} ${pr(count, FILE)} · збережено ${size}`,
  clearedFiles: (n) => `Видалено ${n} ${pr(n, FILE)}.`,
  downloadedTo: (size, name) => `Завантажено ${size} → ${name}.`,
  fileRow: (name, size, when, isEncrypted, totalChunks) =>
    `${name}  ·  ${size}  ·  ${when}  ·  ${isEncrypted ? '🔒 зашифровано' : 'без шифрування'}  ·  ${totalChunks} ${pr(totalChunks, CARD)}`,

  // — log tab (controls only; log ENTRIES stay English) —
  logLevel: 'рівень',
  autoScroll: 'автопрокрутка',
  mirrorToConsole: 'дублювати в консоль',
  clear: 'Очистити',
  copy: 'Копіювати',

  // — inspect dialog —
  close: 'Закрити',
  inspectIdentity: 'Ідентифікація',
  inspectNfar: 'Чанк NFAR',
  inspectRaw: 'Сирі дані',
  inspectHoldStill: 'Тримайте картку нерухомо на зчитувачі…',
  inspectReading: (done, total) => `читання… ${done}/${total}`,
  inspectRead: (done, total) => `прочитано ${done}/${total}`,
  inspectStopped: 'Зупинено.',
  inspectCardLost: 'Картка вийшла з поля — прикладіть знову й повторіть огляд.',
  inspectDone: 'Готово.',

  // — about tab —
  aboutWebVersion: (version, sha) => `Веб-версія ${version} (${sha})`,
  aboutDescription: 'Розподілена система архівації даних з використанням NFC-міток. Зберігайте файли на кількох мітках та відновлюйте їх пізніше — повністю у вашому браузері.',
  aboutSupportedHeading: 'Підтримувані мітки',
  aboutSupportedBody: 'Mifare Classic 1K та NTAG213/215/216 через Chameleon Ultra по Web Bluetooth. Лише NTAG — через власний NFC телефону в Chrome для Android.',
  aboutWebNfcNote: '(NFC телефону читає та пише лише NDEF — для Mifare Classic і огляду картки потрібен Chameleon.)',
  aboutPrivacyHeading: 'Конфіденційність',
  aboutPrivacyBody: 'Усе працює на боці клієнта. Ваші файли, текст і паролі ніколи не залишають браузер — немає ні сервера, ні завантаження, ні стеження.',
  aboutLicensesHeading: 'Ліцензії відкритого коду',
  aboutLicenseApp: 'NFC Archiver — MIT License © 2026 mezinster.',
  aboutLicenseSdk: 'chameleon-ultra.js — MIT License.',

  // — errors (the humanError seam) —
  errCardAuth: 'Ключі картки не заводські — цю картку використати неможливо.',
  errCardRead: 'Картку прочитано не повністю — тримайте її нерухомо на зчитувачі та прикладіть знову.',
  errWriteVerify: 'Перевірка запису не вдалася — піднесіть картку ближче та повторіть.',
  errCardCapacity: 'Ця картка менша за вже записані — використовуйте картки одного типу або почніть архівацію спочатку.',
  errTagTimeout: 'Картку не виявлено — прикладіть картку до зчитувача.',
  errNfarFormat: 'На цій картці немає даних архіву NFAR.',
  errOverwriteRequired: 'На цій картці вже є дані.',
  errPasswordRequired: 'Цей архів зашифровано — введіть пароль.',
  errWrongPassword: 'Неправильний пароль.',
  errUnsupportedTag: 'Мітка не підтримується — використовуйте Mifare Classic 1K або NTAG213/215/216.',
  errUnidentifiedTag: 'Картка не повідомила свій ідентифікатор — приберіть її та прикладіть знову.',
  errNdefFormat: 'На цій мітці немає даних NFAR NDEF.',
};
