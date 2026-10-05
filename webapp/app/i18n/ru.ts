/** Russian catalogue. Shared terms seeded from lib/l10n/app_ru.arb. */
import type { Messages } from './en.js';
import { pr } from './plural.js';

const CARD = { one: 'карта', few: 'карты', many: 'карт', other: 'карт' };
const CARD_GEN = { one: 'карты', few: 'карт', many: 'карт', other: 'карт' };
// Accusative: the impersonal passive «записано» governs the accusative, not the
// nominative CARD table.
const CARD_ACC = { one: 'карту', few: 'карты', many: 'карт', other: 'карт' };
const FILE = { one: 'файл', few: 'файла', many: 'файлов', other: 'файлов' };
const BYTE = { one: 'байт', few: 'байта', many: 'байт', other: 'байт' };

export const ru: Messages = {
  // — shell / device bar —
  connect: 'Подключить Chameleon',
  usePhoneNfc: 'Использовать NFC телефона',
  disconnect: 'Отключить',
  inspectCard: 'Осмотреть карту',
  themeToggle: 'Светлая/тёмная тема',
  language: 'Язык',
  statusConnected: 'подключено',
  statusDisconnected: 'отключено',
  readerDisconnectedClickConnect: 'Считыватель отключён — нажмите «Подключить», чтобы продолжить.',
  inspectNeedsChameleon: 'Для осмотра карты нужен Chameleon — у NFC телефона нет прямого доступа к карте.',
  readerBusyElsewhere: 'Считыватель занят другой операцией — сначала завершите или остановите её.',
  sectionSource: 'Источник',
  sectionSettings: 'Настройки',
  sectionArchives: 'Найденные архивы',
  sectionRestoredFiles: 'Восстановленные файлы',
  sectionLogOptions: 'Параметры журнала',
  subChooseFile: 'Любой файл, разбитый по картам',
  subTypeText: 'Сохраняется как text_note.txt',
  subCompress: 'GZIP перед записью',
  subPassword: 'AES-256-GCM, необязательно',
  subSaveAs: 'Используется, только если в архиве нет имени файла',
  autoDetectNeedsChameleon: 'Выберите тип метки: NFC телефона не может определить ёмкость карты.',

  // — tabs —
  tabArchive: 'Запись',
  tabRestore: 'Чтение',
  tabFiles: 'Файлы',
  tabLog: 'Журнал',
  tabAbout: 'Сведения',

  // — archive tab —
  sourceFile: 'Файл',
  sourceText: 'Текст',
  textPlaceholder: 'Введите текст для архивации в text_note.txt',
  targetAuto: 'Автоопределение (подстроится под карту)',
  compress: 'сжатие',
  archiveToCards: 'Архивировать на карты',
  archiveIdle: 'Подключите Chameleon, затем выберите файл или введите текст.',
  archiveReady: 'Выберите файл или введите текст, затем нажмите «Архивировать на карты».',
  archivePickFirst: 'Сначала выберите файл или введите текст.',
  // — archive write loop —
  progressDone: (written, total) => `✓ записано и проверено ${written} из ${total} ${pr(total, CARD_GEN)}`,
  progressWriting: (written, total) =>
    `✓ записано и проверено ${written} из ${total} — приложите следующую карту`,
  archiveDone: (n) => `Готово — записано и проверено ${n} ${pr(n, CARD_ACC)}.`,
  tapCardOf: (i, total) => `Приложите карту ${i} из ${total} к считывателю…`,
  writingCard: (i, total) => `Запись карты ${i} из ${total} — не убирайте карту…`,
  cardAlreadyWritten: (uid) =>
    `На карту ${uid} уже записана часть этого архива — приложите другую карту (у клонов одинаковый UID).`,
  awaitingOverwriteAnswer: 'На карте уже есть данные — ждём вашего ответа в диалоге…',
  readerDisconnectedResume: 'Считыватель отключён — переподключитесь, чтобы продолжить.',
  readerSwitchedResume: 'Считыватель изменён — продолжаем на новом считывателе.',
  rechunked: (payloadSize, total) =>
    `На карту помещается ${payloadSize} B/chunk — вместо этого ${total} ${pr(total, CARD)}.`,
  noCardTapHold: 'Карта не обнаружена — приложите карту (держите в паре мм от считывателя)…',
  unsupportedTapOther: 'Метка не поддерживается — приложите Mifare Classic 1K или NTAG.',
  skippedTapDifferent: 'Пропущено. Приложите другую карту…',
  retryAfter: (message) => `${message} — приложите снова для повтора.`,
  scanGaveUp: (message) => `Остановлено из-за повторных ошибок: ${message}`,

  // — overwrite dialog —
  overwrite: 'Перезаписать',
  overwriteAll: 'Перезаписать все оставшиеся',
  skip: 'Пропустить',

  // — restore tab —
  scanCards: 'Сканировать карты',
  stop: 'Стоп',
  restoreIdle: 'Подключите Chameleon, затем отсканируйте стопку карт.',
  restoreReady: 'Отсканируйте стопку карт, чтобы найти архивы.',
  scanning: 'Сканирование — прикладывайте карты к считывателю…',
  tapMoreCards: 'Приложите ещё карты или восстановите готовый архив.',
  skippedCard: (message) => `Карта пропущена: ${message}`,
  restore: 'Восстановить',
  restoredBytes: (bytes, name) => `Восстановлено ${bytes} ${pr(bytes, BYTE)} → ${name}.`,

  // — passwords —
  promptArchiveEncrypted: 'Этот архив зашифрован. Введите пароль:',
  promptFileEncrypted: 'Этот файл зашифрован. Введите пароль:',
  promptWrongPassword: 'Неверный пароль. Введите пароль:',
  tooManyPasswordAttempts: 'Слишком много неудачных попыток ввода пароля.',
  cancelled: 'Отменено.',

  // — files tab —
  filesEmpty: 'Восстановленных файлов пока нет. Восстановите архив — и он появится здесь.',
  clearAll: 'Очистить всё',
  confirmClearAll: 'Удалить все сохранённые файлы? Это действие нельзя отменить.',
  download: 'Скачать',
  deleteBtn: 'Удалить',
  filesInfo: (count, size) => `${count} ${pr(count, FILE)} · сохранено ${size}`,
  clearedFiles: (n) => `Удалено ${n} ${pr(n, FILE)}.`,
  downloadedTo: (size, name) => `Скачано ${size} → ${name}.`,
  // — log tab (controls only; log ENTRIES stay English) —
  logLevel: 'уровень',
  autoScroll: 'автопрокрутка',
  mirrorToConsole: 'дублировать в консоль',
  clear: 'Очистить',
  copy: 'Копировать',

  // — inspect dialog —
  close: 'Закрыть',
  inspectIdentity: 'Идентификация',
  inspectNfar: 'Чанк NFAR',
  inspectRaw: 'Сырые данные',
  inspectHoldStill: 'Держите карту неподвижно на считывателе…',
  inspectReading: (done, total) => `чтение… ${done}/${total}`,
  inspectRead: (done, total) => `прочитано ${done}/${total}`,
  inspectStopped: 'Остановлено.',
  inspectCardLost: 'Карта вышла из поля — приложите снова и повторите осмотр.',
  inspectDone: 'Готово.',

  // — about tab —
  aboutWebVersion: (version, sha) => `Веб-версия ${version} (${sha})`,
  aboutDescription: 'Распределённая система архивации данных с использованием NFC-меток. Храните файлы на нескольких метках и восстанавливайте их позже — полностью в браузере.',
  aboutSupportedHeading: 'Поддерживаемые метки',
  aboutSupportedBody: 'Mifare Classic 1K и NTAG213/215/216 через Chameleon Ultra по Web Bluetooth. Только NTAG — через собственный NFC телефона в Chrome для Android.',
  aboutWebNfcNote: '(NFC телефона читает и пишет только NDEF — для Mifare Classic и осмотра карты нужен Chameleon.)',
  aboutPrivacyHeading: 'Конфиденциальность',
  aboutPrivacyBody: 'Всё работает на стороне клиента. Ваши файлы, текст и пароли никогда не покидают браузер — нет ни сервера, ни загрузки, ни слежки.',
  aboutLicensesHeading: 'Лицензии открытого кода',
  aboutLicenseApp: 'NFC Archiver — MIT License © 2026 mezinster.',
  aboutLicenseSdk: 'chameleon-ultra.js — MIT License.',

  // — errors (the humanError seam) —
  errCardAuth: 'Ключи карты не заводские — эту карту использовать нельзя.',
  errCardRead: 'Карта прочитана не полностью — держите её неподвижно на считывателе и приложите снова.',
  errWriteVerify: 'Проверка записи не удалась — поднесите карту ближе и повторите.',
  errCardCapacity: 'Эта карта меньше уже записанных — используйте карты одного типа или начните архивацию заново.',
  errTagTimeout: 'Карта не обнаружена — приложите карту к считывателю.',
  errNfarFormat: 'На этой карте нет данных архива NFAR.',
  errOverwriteRequired: 'На этой карте уже есть данные.',
  errPasswordRequired: 'Этот архив зашифрован — введите пароль.',
  errWrongPassword: 'Неверный пароль.',
  errUnsupportedTag: 'Метка не поддерживается — используйте Mifare Classic 1K или NTAG213/215/216.',
  errUnidentifiedTag: 'Карта не сообщила свой идентификатор — уберите её и приложите снова.',
  errNdefFormat: 'На этой метке нет данных NFAR NDEF.',

  // — redesign 2026-10 —
  encryptedLabel: 'Зашифровано',
  stopping: 'Остановка…',
  restoreWebNfcMifareNote: 'NFC телефона читает только архивы на NTAG. Карты Mifare Classic не доходят до браузера — чтобы прочитать их, подключите Chameleon или используйте приложение для Android.',
  readerConnectTitle: 'Подключите считыватель',
  readerConnectBody: 'Chameleon Ultra по Bluetooth или NFC этого телефона (Chrome на Android, только NTAG).',
  readerNamePhone: 'NFC телефона',
  inspect: 'Осмотреть',
  connectReaderFirst: 'Сначала подключите считыватель',
  sourceChooseFile: 'Нажмите, чтобы выбрать файл',
  sourceTapToChange: 'Нажмите, чтобы изменить',
  tagTypeLabel: 'Тип метки',
  passwordLabel: 'Пароль (необязательно)',
  saveAsLabel: 'Сохранить как',
  cardsNeeded: (n) => `≈ ${n} ${pr(n, CARD)} для записи`,
  estimateAuto: 'Автоопределение · подстроится под приложенную карту',
  slotCard: (n) => `Карта ${n}`,
  slotWritten: 'Записана',
  slotWriting: 'Запись',
  slotWaiting: 'Ожидает',
  slotHasData: 'Есть данные',
  cardOfTotal: (i, n) => `Карта ${i} из ${n}`,
  archiveAgain: 'Архивировать ещё',
  back: 'Назад',
  archiveStoppedPartial: (written, total) => `Остановлено — записано ${written} из ${total}. Архив неполный.`,
  scanStageTitle: 'Прикладывайте карты в любом порядке',
  archiveRowStatus: (received, total, complete) => `${received} из ${total}${complete ? ' · готово' : ''}`,
  fileRowMeta: (size, totalChunks, when) => `${size} · ${totalChunks} ${pr(totalChunks, CARD)} · ${when}`,
  overwriteTitle: 'На карте уже есть данные',
  overwriteBody: 'Перезапись сотрёт её содержимое.',
};
