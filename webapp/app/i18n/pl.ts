/** Polish catalogue. Shared terms seeded from lib/l10n/app_pl.arb. */
import type { Messages } from './en.js';
import { pr } from './plural.js';

const CARD = { one: 'karta', few: 'karty', many: 'kart', other: 'kart' };
const CARD_GEN = { one: 'karty', few: 'kart', many: 'kart', other: 'kart' };
// Accusative: the impersonal passive „zapisano” governs the accusative, not the
// nominative CARD table.
const CARD_ACC = { one: 'kartę', few: 'karty', many: 'kart', other: 'kart' };
const FILE = { one: 'plik', few: 'pliki', many: 'plików', other: 'plików' };
const BYTE = { one: 'bajt', few: 'bajty', many: 'bajtów', other: 'bajtów' };

export const pl: Messages = {
  // — shell / device bar —
  connect: 'Połącz z Chameleonem',
  usePhoneNfc: 'Użyj NFC telefonu',
  disconnect: 'Rozłącz',
  inspectCard: 'Zbadaj kartę',
  themeToggle: 'Przełącz jasny/ciemny motyw',
  language: 'Język',
  statusConnected: 'połączono',
  statusDisconnected: 'rozłączono',
  connectedDot: 'Połączono.',
  connectedPhoneNfc: 'Używane NFC telefonu.',
  readerDisconnectedClickConnect: 'Czytnik rozłączony — kliknij „Połącz”, aby kontynuować.',
  inspectNeedsChameleon: 'Zbadanie karty wymaga Chameleona — NFC telefonu nie ma bezpośredniego dostępu do karty.',
  readerBusyElsewhere: 'Czytnik jest zajęty inną operacją — najpierw ją zakończ lub zatrzymaj.',
  autoDetectNeedsChameleon: 'Wybierz typ znacznika: NFC telefonu nie potrafi wykryć pojemności karty.',

  // — tabs —
  tabArchive: 'Archiwizuj',
  tabRestore: 'Przywróć',
  tabFiles: 'Pliki',
  tabLog: 'Dziennik',
  tabAbout: 'O aplikacji',

  // — archive tab —
  orText: 'lub tekst:',
  textPlaceholder: 'Wpisz tekst do zarchiwizowania jako text_note.txt',
  targetTag: 'typ tagu',
  targetAuto: 'Wykryj automatycznie (dopasuje się do karty)',
  compress: 'kompresja',
  password: 'hasło',
  optionalPlaceholder: '(opcjonalnie)',
  archiveToCards: 'Archiwizuj na karty',
  archiveIdle: 'Podłącz Chameleon, a następnie wybierz plik lub wpisz tekst.',
  archiveReady: 'Wybierz plik lub wpisz tekst, a następnie kliknij „Archiwizuj na karty”.',
  archivePickFirst: 'Najpierw wybierz plik lub wpisz tekst.',
  cardEstimate: (n, isAuto) =>
    `≈ ${n} ${pr(n, CARD)}${isAuto ? ' (szac.) — dopasuje się do przyłożonej karty' : ''}`,

  // — archive write loop —
  progressDone: (written, total) => `✓ zapisano i zweryfikowano ${written} z ${total} ${pr(total, CARD_GEN)}`,
  progressWriting: (written, total) =>
    `✓ zapisano i zweryfikowano ${written} z ${total} — przyłóż następną kartę`,
  archiveDone: (n) => `Gotowe — zapisano i zweryfikowano ${n} ${pr(n, CARD_ACC)}.`,
  tapCardOf: (i, total) => `Przyłóż kartę ${i} z ${total} do czytnika…`,
  readerDisconnectedResume: 'Czytnik rozłączony — połącz ponownie, aby kontynuować.',
  readerSwitchedResume: 'Zmieniono czytnik — wznawianie na nowym czytniku.',
  rechunked: (payloadSize, total) =>
    `Na karcie mieści się ${payloadSize} B/chunk — zamiast tego ${total} ${pr(total, CARD)}.`,
  noCardTapHold: 'Nie wykryto karty — przyłóż kartę (trzymaj kilka mm od czytnika)…',
  unsupportedTapOther: 'Nieobsługiwany tag — przyłóż Mifare Classic 1K lub NTAG.',
  skippedTapDifferent: 'Pominięto. Przyłóż inną kartę…',
  retryAfter: (message) => `${message} — przyłóż ponownie, aby spróbować jeszcze raz.`,
  scanGaveUp: (message) => `Zatrzymano po powtarzających się błędach: ${message}`,

  // — overwrite dialog —
  overwrite: 'Nadpisz',
  overwriteAll: 'Nadpisz wszystkie pozostałe',
  skip: 'Pomiń',

  // — restore tab —
  scanCards: 'Skanuj karty',
  stop: 'Zatrzymaj',
  saveAs: 'zapisz jako',
  restoreIdle: 'Podłącz Chameleon, a następnie zeskanuj stos kart.',
  restoreReady: 'Zeskanuj stos kart, aby wykryć archiwa.',
  scanning: 'Skanowanie — przykładaj karty do czytnika…',
  tapMoreCards: 'Przyłóż więcej kart lub przywróć kompletne archiwum.',
  skippedCard: (message) => `Pominięto kartę: ${message}`,
  restore: 'Przywróć',
  archiveRow: (shortId, isEncrypted, received, total, complete) =>
    `Archiwum ${shortId}…  ${isEncrypted ? '🔒 zaszyfrowane' : 'niezaszyfrowane'}  ·  ${received} / ${total} ${pr(total, CARD)}${complete ? ' ✓' : ''}`,
  restoredBytes: (bytes, name) => `Przywrócono ${bytes} ${pr(bytes, BYTE)} → ${name}.`,

  // — passwords —
  promptArchiveEncrypted: 'To archiwum jest zaszyfrowane. Wprowadź hasło:',
  promptFileEncrypted: 'Ten plik jest zaszyfrowany. Wprowadź hasło:',
  promptWrongPassword: 'Nieprawidłowe hasło. Wprowadź hasło:',
  tooManyPasswordAttempts: 'Zbyt wiele nieudanych prób wprowadzenia hasła.',
  cancelled: 'Anulowano.',

  // — files tab —
  filesEmpty: 'Brak przywróconych plików. Przywróć archiwum, a pojawi się tutaj.',
  clearAll: 'Wyczyść wszystko',
  confirmClearAll: 'Usunąć wszystkie zapisane pliki? Tego nie można cofnąć.',
  download: 'Pobierz',
  deleteBtn: 'Usuń',
  filesInfo: (count, size) => `${count} ${pr(count, FILE)} · zapisano ${size}`,
  clearedFiles: (n) => `Usunięto ${n} ${pr(n, FILE)}.`,
  downloadedTo: (size, name) => `Pobrano ${size} → ${name}.`,
  fileRow: (name, size, when, isEncrypted, totalChunks) =>
    `${name}  ·  ${size}  ·  ${when}  ·  ${isEncrypted ? '🔒 zaszyfrowane' : 'bez szyfrowania'}  ·  ${totalChunks} ${pr(totalChunks, CARD)}`,

  // — log tab (controls only; log ENTRIES stay English) —
  logLevel: 'poziom',
  autoScroll: 'autoprzewijanie',
  mirrorToConsole: 'kopiuj do konsoli',
  clear: 'Wyczyść',
  copy: 'Kopiuj',

  // — inspect dialog —
  close: 'Zamknij',
  inspectIdentity: 'Identyfikacja',
  inspectNfar: 'Fragment NFAR',
  inspectRaw: 'Dane surowe',
  inspectHoldStill: 'Trzymaj kartę nieruchomo na czytniku…',
  inspectReading: (done, total) => `odczyt… ${done}/${total}`,
  inspectRead: (done, total) => `odczytano ${done}/${total}`,
  inspectStopped: 'Zatrzymano.',
  inspectCardLost: 'Karta opuściła pole — przyłóż ponownie i zbadaj jeszcze raz.',
  inspectDone: 'Gotowe.',

  // — about tab —
  aboutWebVersion: (version, sha) => `Wersja webowa ${version} (${sha})`,
  aboutDescription: 'Rozproszony system archiwizacji danych wykorzystujący tagi NFC. Przechowuj pliki na wielu tagach i przywracaj je później — w całości w przeglądarce.',
  aboutSupportedHeading: 'Obsługiwane tagi',
  aboutSupportedBody: 'Mifare Classic 1K i NTAG213/215/216 przez Chameleon Ultra po Web Bluetooth.',
  aboutWebNfcNote: '(Zapis NTAG za pomocą własnego NFC telefonu — bez urządzenia Chameleon — pojawi się wraz z przyszłą obsługą Web NFC.)',
  aboutPrivacyHeading: 'Prywatność',
  aboutPrivacyBody: 'Wszystko działa po stronie klienta. Twoje pliki, tekst i hasła nigdy nie opuszczają przeglądarki — nie ma serwera, przesyłania ani śledzenia.',
  aboutLicensesHeading: 'Licencje open source',
  aboutLicenseApp: 'NFC Archiver — MIT License © 2026 mezinster.',
  aboutLicenseSdk: 'chameleon-ultra.js — MIT License.',

  // — errors (the humanError seam) —
  errCardAuth: 'Klucze karty nie są fabryczne — tej karty nie można użyć.',
  errCardRead: 'Odczyt karty był niepełny — trzymaj kartę nieruchomo na czytniku i przyłóż ponownie.',
  errWriteVerify: 'Weryfikacja zapisu nie powiodła się — przysuń kartę bliżej i spróbuj ponownie.',
  errCardCapacity: 'Ta karta jest mniejsza niż już zapisane — używaj kart tego samego typu lub zacznij archiwizację od nowa.',
  errTagTimeout: 'Nie wykryto karty — przyłóż kartę do czytnika.',
  errNfarFormat: 'Ta karta nie zawiera danych archiwum NFAR.',
  errOverwriteRequired: 'Ta karta już zawiera dane.',
  errPasswordRequired: 'To archiwum jest zaszyfrowane — wprowadź hasło.',
  errWrongPassword: 'Nieprawidłowe hasło.',
  errUnsupportedTag: 'Nieobsługiwany tag — użyj Mifare Classic 1K lub NTAG213/215/216.',
  errUnidentifiedTag: 'Karta nie podała swojego identyfikatora — odsuń ją i przyłóż ponownie.',
  errNdefFormat: 'Ten tag nie zawiera danych NFAR NDEF.',
};
