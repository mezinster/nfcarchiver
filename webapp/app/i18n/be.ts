/** Belarusian catalogue. Shared terms seeded from lib/l10n/app_be.arb. */
import type { Messages } from './en.js';
import { pr } from './plural.js';

const CARD = { one: 'карта', few: 'карты', many: 'карт', other: 'карт' };
const CARD_GEN = { one: 'карты', few: 'карт', many: 'карт', other: 'карт' };
// Accusative: the impersonal passive «запісана» governs the accusative, not the
// nominative CARD table.
const CARD_ACC = { one: 'карту', few: 'карты', many: 'карт', other: 'карт' };
const FILE = { one: 'файл', few: 'файлы', many: 'файлаў', other: 'файлаў' };
const BYTE = { one: 'байт', few: 'байты', many: 'байтаў', other: 'байтаў' };

export const be: Messages = {
  // — shell / device bar —
  connect: 'Падключыць Chameleon',
  usePhoneNfc: 'Выкарыстаць NFC тэлефона',
  disconnect: 'Адключыць',
  inspectCard: 'Агледзець карту',
  themeToggle: 'Светлая/цёмная тэма',
  language: 'Мова',
  statusConnected: 'падключана',
  statusDisconnected: 'адключана',
  connectedDot: 'Падключана.',
  connectedPhoneNfc: 'Выкарыстоўваецца NFC тэлефона.',
  readerDisconnectedClickConnect: 'Счытвальнік адключаны — націсніце «Падключыць», каб працягнуць.',
  inspectNeedsChameleon: 'Для агляду карты патрэбны Chameleon — NFC тэлефона не мае прамога доступу да карты.',
  autoDetectNeedsChameleon: 'Абярыце тып меткі: NFC тэлефона не можа вызначыць ёмістасць карты.',

  // — tabs —
  tabArchive: 'Архіваваць',
  tabRestore: 'Аднавіць',
  tabFiles: 'Файлы',
  tabLog: 'Журнал',
  tabAbout: 'Пра праграму',

  // — archive tab —
  orText: 'або тэкст:',
  textPlaceholder: 'Увядзіце тэкст для архівацыі ў text_note.txt',
  targetTag: 'тып меткі',
  targetAuto: 'Аўтавызначэнне (падладзіцца пад карту)',
  compress: 'сціск',
  password: 'пароль',
  optionalPlaceholder: '(неабавязкова)',
  archiveToCards: 'Архіваваць на карты',
  archiveIdle: 'Падключыце Chameleon, потым выберыце файл або ўвядзіце тэкст.',
  archiveReady: 'Выберыце файл або ўвядзіце тэкст, потым націсніце «Архіваваць на карты».',
  archivePickFirst: 'Спачатку выберыце файл або ўвядзіце тэкст.',
  cardEstimate: (n, isAuto) =>
    `≈ ${n} ${pr(n, CARD)}${isAuto ? ' (прыблізна) — падладзіцца пад карту' : ''}`,

  // — archive write loop —
  progressDone: (written, total) => `✓ запісана і праверана ${written} з ${total} ${pr(total, CARD_GEN)}`,
  progressWriting: (written, total) =>
    `✓ запісана і праверана ${written} з ${total} — прыкладзіце наступную карту`,
  archiveDone: (n) => `Гатова — запісана і праверана ${n} ${pr(n, CARD_ACC)}.`,
  tapCardOf: (i, total) => `Прыкладзіце карту ${i} з ${total} да счытвальніка…`,
  readerDisconnectedResume: 'Счытвальнік адключаны — падключыцеся зноў, каб працягнуць.',
  rechunked: (payloadSize, total) =>
    `На карту змяшчаецца ${payloadSize} B/chunk — замест гэтага ${total} ${pr(total, CARD)}.`,
  noCardTapHold: 'Карта не выяўлена — прыкладзіце карту (трымайце за некалькі мм ад счытвальніка)…',
  unsupportedTapOther: 'Метка не падтрымліваецца — прыкладзіце Mifare Classic 1K або NTAG.',
  skippedTapDifferent: 'Прапушчана. Прыкладзіце іншую карту…',
  retryAfter: (message) => `${message} — прыкладзіце зноў, каб паўтарыць.`,

  // — overwrite dialog —
  overwrite: 'Перазапісаць',
  overwriteAll: 'Перазапісаць усе астатнія',
  skip: 'Прапусціць',

  // — restore tab —
  scanCards: 'Сканаваць карты',
  stop: 'Спыніць',
  saveAs: 'захаваць як',
  restoreIdle: 'Падключыце Chameleon, потым адсканіруйце стос карт.',
  restoreReady: 'Адсканіруйце стос карт, каб знайсці архівы.',
  scanning: 'Сканаванне — прыкладайце карты да счытвальніка…',
  tapMoreCards: 'Прыкладзіце яшчэ карты або аднавіце гатовы архіў.',
  skippedCard: (message) => `Карта прапушчана: ${message}`,
  restore: 'Аднавіць',
  archiveRow: (shortId, isEncrypted, received, total, complete) =>
    `Архіў ${shortId}…  ${isEncrypted ? '🔒 зашыфравана' : 'без шыфравання'}  ·  ${received} / ${total} ${pr(total, CARD)}${complete ? ' ✓' : ''}`,
  restoredBytes: (bytes, name) => `Адноўлена ${bytes} ${pr(bytes, BYTE)} → ${name}.`,

  // — passwords —
  promptArchiveEncrypted: 'Гэты архіў зашыфраваны. Увядзіце пароль:',
  promptFileEncrypted: 'Гэты файл зашыфраваны. Увядзіце пароль:',
  promptWrongPassword: 'Няправільны пароль. Увядзіце пароль:',
  tooManyPasswordAttempts: 'Занадта шмат няўдалых спроб уводу пароля.',
  cancelled: 'Адменена.',

  // — files tab —
  filesEmpty: 'Адноўленых файлаў пакуль няма. Аднавіце архіў — і ён з’явіцца тут.',
  clearAll: 'Ачысціць усё',
  confirmClearAll: 'Выдаліць усе захаваныя файлы? Гэта нельга адмяніць.',
  download: 'Спампаваць',
  deleteBtn: 'Выдаліць',
  filesInfo: (count, size) => `${count} ${pr(count, FILE)} · захавана ${size}`,
  clearedFiles: (n) => `Выдалена ${n} ${pr(n, FILE)}.`,
  downloadedTo: (size, name) => `Спампавана ${size} → ${name}.`,
  fileRow: (name, size, when, isEncrypted, totalChunks) =>
    `${name}  ·  ${size}  ·  ${when}  ·  ${isEncrypted ? '🔒 зашыфравана' : 'без шыфравання'}  ·  ${totalChunks} ${pr(totalChunks, CARD)}`,

  // — log tab (controls only; log ENTRIES stay English) —
  logLevel: 'узровень',
  autoScroll: 'аўтапракрутка',
  mirrorToConsole: 'дубляваць у кансоль',
  clear: 'Ачысціць',
  copy: 'Капіраваць',

  // — inspect dialog —
  close: 'Закрыць',
  inspectIdentity: 'Ідэнтыфікацыя',
  inspectNfar: 'Фрагмент NFAR',
  inspectRaw: 'Сырыя даныя',
  inspectHoldStill: 'Трымайце карту нерухома на счытвальніку…',
  inspectReading: (done, total) => `чытанне… ${done}/${total}`,
  inspectRead: (done, total) => `прачытана ${done}/${total}`,
  inspectStopped: 'Спынена.',
  inspectCardLost: 'Карта выйшла з поля — прыкладзіце зноў і паўтарыце агляд.',
  inspectDone: 'Гатова.',

  // — about tab —
  aboutWebVersion: (version, sha) => `Вэб-версія ${version} (${sha})`,
  aboutDescription: 'Размеркаваная сістэма архівацыі даных з выкарыстаннем NFC-метак. Захоўвайце файлы на некалькіх метках і аднаўляйце іх пазней — цалкам у вашым браўзеры.',
  aboutSupportedHeading: 'Падтрыманыя меткі',
  aboutSupportedBody: 'Mifare Classic 1K і NTAG213/215/216 праз Chameleon Ultra па Web Bluetooth.',
  aboutWebNfcNote: '(Запіс NTAG уласным NFC тэлефона — без Chameleon — з’явіцца разам з будучай падтрымкай Web NFC.)',
  aboutPrivacyHeading: 'Прыватнасць',
  aboutPrivacyBody: 'Усё працуе на баку кліента. Вашы файлы, тэкст і паролі ніколі не пакідаюць браўзер — няма ні сервера, ні запампоўкі, ні сачэння.',
  aboutLicensesHeading: 'Ліцэнзіі адкрытага кода',
  aboutLicenseApp: 'NFC Archiver — MIT License © 2026 mezinster.',
  aboutLicenseSdk: 'chameleon-ultra.js — MIT License.',

  // — errors (the humanError seam) —
  errCardAuth: 'Ключы карты не заводскія — гэту карту немагчыма выкарыстаць.',
  errCardRead: 'Карта прачытана не цалкам — трымайце яе нерухома на счытвальніку і прыкладзіце зноў.',
  errWriteVerify: 'Праверка запісу не ўдалася — паднясіце карту бліжэй і паўтарыце.',
  errCardCapacity: 'Гэта карта меншая за ўжо запісаныя — выкарыстоўвайце карты аднаго тыпу або пачніце архівацыю спачатку.',
  errTagTimeout: 'Карта не выяўлена — прыкладзіце карту да счытвальніка.',
  errNfarFormat: 'На гэтай карце няма даных архіва NFAR.',
  errOverwriteRequired: 'На гэтай карце ўжо ёсць даныя.',
  errPasswordRequired: 'Гэты архіў зашыфраваны — увядзіце пароль.',
  errWrongPassword: 'Няправільны пароль.',
  errUnsupportedTag: 'Метка не падтрымліваецца — выкарыстоўвайце Mifare Classic 1K або NTAG213/215/216.',
  errNdefFormat: 'На гэтай метцы няма даных NFAR NDEF.',
};
