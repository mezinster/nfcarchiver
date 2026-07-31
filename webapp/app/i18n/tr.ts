/** Turkish catalogue. Shared terms seeded from lib/l10n/app_tr.arb. */
import type { Messages } from './en.js';
import { pr } from './plural.js';

// Turkish nouns take no plural suffix after a numeral ("5 kart", not "5 kartlar"),
// so both categories are the same word. `other` is still required by PluralForms.
const CARD = { one: 'kart', other: 'kart' };
const FILE = { one: 'dosya', other: 'dosya' };

export const tr: Messages = {
  // — shell / device bar —
  connect: "Chameleon'a bağlan",
  usePhoneNfc: "Telefonun NFC'sini kullan",
  disconnect: 'Bağlantıyı kes',
  inspectCard: 'Kartı incele',
  themeToggle: 'Açık/koyu tema',
  language: 'Dil',
  statusConnected: 'bağlı',
  statusDisconnected: 'bağlı değil',
  connectedDot: 'Bağlandı.',
  connectedPhoneNfc: "Telefonun NFC'si kullanılıyor.",
  readerDisconnectedClickConnect: "Okuyucu bağlantısı kesildi — devam etmek için Bağlan'a tıklayın.",
  inspectNeedsChameleon: "Kart incelemesi için Chameleon gerekir — telefonun NFC'sinin ham karta erişimi yoktur.",
  autoDetectNeedsChameleon: "Bir etiket türü seçin: telefonun NFC'si kart kapasitesini algılayamaz.",

  // — tabs —
  tabArchive: 'Arşivle',
  tabRestore: 'Geri yükle',
  tabFiles: 'Dosyalar',
  tabLog: 'Günlük',
  tabAbout: 'Hakkında',

  // — archive tab —
  orText: 'veya metin:',
  textPlaceholder: 'text_note.txt olarak arşivlenecek metni yazın',
  targetTag: 'hedef etiket',
  targetAuto: 'Otomatik algıla (karta uyarlanır)',
  compress: 'sıkıştır',
  password: 'şifre',
  optionalPlaceholder: '(isteğe bağlı)',
  archiveToCards: 'Kartlara arşivle',
  archiveIdle: 'Bir Chameleon bağlayın, ardından dosya seçin veya metin yazın.',
  archiveReady: "Bir dosya seçin veya metin yazın, sonra Kartlara arşivle'ye basın.",
  archivePickFirst: 'Önce bir dosya seçin veya biraz metin yazın.',
  cardEstimate: (n, isAuto) =>
    `≈ ${n} ${pr(n, CARD)}${isAuto ? ' (tahmini) — okutulan karta uyarlanır' : ''}`,

  // — archive write loop —
  progressDone: (written, total) => `✓ ${total} karttan ${written} tanesi yazıldı ve doğrulandı`,
  progressWriting: (written, total) =>
    `✓ ${total} karttan ${written} tanesi yazıldı ve doğrulandı — sonraki kartı okutun`,
  archiveDone: (n) => `Bitti — ${n} ${pr(n, CARD)} yazıldı ve doğrulandı.`,
  tapCardOf: (i, total) => `Kart ${i}/${total} — okuyucuya okutun…`,
  readerDisconnectedResume: 'Okuyucu bağlantısı kesildi — devam etmek için yeniden bağlanın.',
  rechunked: (payloadSize, total) =>
    `Kart ${payloadSize} B/chunk alıyor — bunun yerine ${total} ${pr(total, CARD)} yazılıyor.`,
  noCardTapHold: 'Kart algılanmadı — bir kart okutun (birkaç mm uzakta tutun)…',
  unsupportedTapOther: 'Desteklenmeyen etiket — Mifare Classic 1K veya NTAG okutun.',
  skippedTapDifferent: 'Atlandı. Farklı bir kart okutun…',
  retryAfter: (message) => `${message} — yeniden denemek için tekrar okutun.`,

  // — overwrite dialog —
  overwrite: 'Üzerine yaz',
  overwriteAll: 'Kalan hepsinin üzerine yaz',
  skip: 'Atla',

  // — restore tab —
  scanCards: 'Kartları tara',
  stop: 'Durdur',
  saveAs: 'şu adla kaydet',
  restoreIdle: 'Bir Chameleon bağlayın, ardından bir deste kartı tarayın.',
  restoreReady: 'Arşivleri bulmak için bir deste kartı tarayın.',
  scanning: 'Taranıyor — kartları okuyucuya okutun…',
  tapMoreCards: 'Daha fazla kart okutun veya tamamlanmış bir arşivi geri yükleyin.',
  skippedCard: (message) => `Bir kart atlandı: ${message}`,
  restore: 'Geri yükle',
  archiveRow: (shortId, isEncrypted, received, total, complete) =>
    `Arşiv ${shortId}…  ${isEncrypted ? '🔒 şifreli' : 'şifresiz'}  ·  ${received} / ${total} ${pr(total, CARD)}${complete ? ' ✓' : ''}`,
  restoredBytes: (bytes, name) => `${bytes} bayt geri yüklendi → ${name}.`,

  // — passwords —
  promptArchiveEncrypted: 'Bu arşiv şifrelenmiş. Şifreyi girin:',
  promptFileEncrypted: 'Bu dosya şifrelenmiş. Şifreyi girin:',
  promptWrongPassword: 'Yanlış şifre. Şifreyi girin:',
  tooManyPasswordAttempts: 'Çok fazla hatalı şifre denemesi.',
  cancelled: 'İptal edildi.',

  // — files tab —
  filesEmpty: 'Henüz geri yüklenmiş dosya yok. Bir arşivi geri yükleyin, burada görünecek.',
  clearAll: 'Tümünü temizle',
  confirmClearAll: 'Saklanan tüm dosyalar silinsin mi? Bu işlem geri alınamaz.',
  download: 'İndir',
  deleteBtn: 'Sil',
  filesInfo: (count, size) => `${count} ${pr(count, FILE)} · ${size} saklanıyor`,
  clearedFiles: (n) => `${n} ${pr(n, FILE)} silindi.`,
  downloadedTo: (size, name) => `${size} indirildi → ${name}.`,
  fileRow: (name, size, when, isEncrypted, totalChunks) =>
    `${name}  ·  ${size}  ·  ${when}  ·  ${isEncrypted ? '🔒 şifreli' : 'şifresiz'}  ·  ${totalChunks} ${pr(totalChunks, CARD)}`,

  // — log tab (controls only; log ENTRIES stay English) —
  logLevel: 'düzey',
  autoScroll: 'otomatik kaydır',
  mirrorToConsole: 'konsola yansıt',
  clear: 'Temizle',
  copy: 'Kopyala',

  // — inspect dialog —
  close: 'Kapat',
  inspectIdentity: 'Kimlik',
  inspectNfar: 'NFAR parçası',
  inspectRaw: 'Ham veri',
  inspectHoldStill: 'Kartı okuyucunun üzerinde sabit tutun…',
  inspectReading: (done, total) => `okunuyor… ${done}/${total}`,
  inspectRead: (done, total) => `${done}/${total} okundu`,
  inspectStopped: 'Durduruldu.',
  inspectCardLost: 'Kart alandan çıktı — tekrar okutup yeniden inceleyin.',
  inspectDone: 'Bitti.',

  // — about tab —
  aboutWebVersion: (version, sha) => `Web sürümü ${version} (${sha})`,
  aboutDescription: 'NFC etiketleri kullanan dağıtık veri arşivleme sistemi. Dosyaları birden fazla etikette saklayın ve daha sonra geri yükleyin — tamamen tarayıcınızda.',
  aboutSupportedHeading: 'Desteklenen etiketler',
  aboutSupportedBody: 'Web Bluetooth üzerinden bir Chameleon Ultra ile Mifare Classic 1K ve NTAG213/215/216.',
  aboutWebNfcNote: "(NTAG'e telefonun kendi NFC'siyle — Chameleon olmadan — yazmak, gelecekteki Web NFC desteğiyle birlikte gelecek.)",
  aboutPrivacyHeading: 'Gizlilik',
  aboutPrivacyBody: 'Her şey istemci tarafında çalışır. Dosyalarınız, metinleriniz ve şifreleriniz tarayıcıdan asla çıkmaz — sunucu, yükleme ve takip yoktur.',
  aboutLicensesHeading: 'Açık kaynak lisansları',
  aboutLicenseApp: 'NFC Archiver — MIT License © 2026 mezinster.',
  aboutLicenseSdk: 'chameleon-ultra.js — MIT License.',

  // — errors (the humanError seam) —
  errCardAuth: 'Kart anahtarları fabrika varsayılanı değil — bu kart kullanılamaz.',
  errCardRead: 'Kart okuma tamamlanmadı — kartı okuyucunun üzerinde sabit tutup tekrar okutun.',
  errWriteVerify: 'Yazma doğrulaması başarısız — kartı yaklaştırıp tekrar deneyin.',
  errCardCapacity: 'Bu kart daha önce yazılanlardan küçük — aynı türde kartlar kullanın veya arşivi yeniden başlatın.',
  errTagTimeout: 'Kart algılanmadı — okuyucuya bir kart okutun.',
  errNfarFormat: 'Bu kartta NFAR arşiv verisi yok.',
  errOverwriteRequired: 'Bu kartta zaten veri var.',
  errPasswordRequired: 'Bu arşiv şifrelenmiş — bir şifre girin.',
  errWrongPassword: 'Yanlış şifre.',
  errUnsupportedTag: 'Desteklenmeyen etiket — Mifare Classic 1K veya NTAG213/215/216 kullanın.',
  errNdefFormat: 'Bu etikette NFAR NDEF verisi yok.',
};
