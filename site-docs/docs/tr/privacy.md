# Gizlilik politikası

*Geçerli olan metin İngilizce sürümdür: [Privacy policy](../../privacy/).*

**NFC Archiver** · Son güncelleme: 11 Kasım 2026

## Özet

NFC Archiver tamamen çevrimdışı çalışır. Kişisel veri toplamaz ve göndermez; analiz, reklam ya da izleme içermez. NFC'yi, Bluetooth'u (yalnızca size ait bir Chameleon Ultra okuyucuyla konuşmak için) ve kendi seçtiğiniz dosyaları kullanır.

## Veri toplama

**Hiçbir veri toplamıyoruz.** Ayrıntılı olarak:

- Kişisel bilgi toplanmaz.
- Kullanım analizi veya izleme yoktur.
- Hiçbir yere çökme raporu gönderilmez.
- Çerez veya tanımlayıcı yoktur.
- Reklam veya pazarlama verisi yoktur.

## NFC

NFC yalnızca telefonunuza yaklaştırdığınız fiziksel NFC etiketlerine veri okumak ve yazmak için kullanılır. Tüm NFC işlemleri yereldir; ağ üzerinden hiçbir şey gönderilmez.

## Bluetooth

Bluetooth yalnızca size ait bir Chameleon Ultra okuyucuya bağlanmak için kullanılır; böylece uygulama Mifare Classic kartları bu okuyucu üzerinden okuyup yazabilir. Bağlantı yereldir, telefonunuz ile okuyucu arasındadır. Bu nedenle cihazınızdan hiçbir veri çıkmaz ve uygulama konumunuzu belirlemek için Bluetooth'u kullanmaz.

## Dosyalar

Arşivlemek için seçtiğiniz dosyalar tamamen cihazınızda işlenir. Bir dosya:

- sistemin dosya seçicisi aracılığıyla cihazınızdan okunur;
- isteğe bağlı olarak cihazda sıkıştırılır (GZIP);
- isteğe bağlı olarak cihazda şifrelenir (AES-256-GCM);
- parçalara bölünür ve NFC etiketlerine yazılır.

Dosya verileri hiçbir zaman bir sunucuya yüklenmez, paylaşılmaz veya gönderilmez. Geri yüklenen dosyalar uygulamanın özel depolama alanına kaydedilir ve yalnızca siz Aç, Cihaza kaydet veya Paylaş'ı seçtiğinizde bu alandan çıkar. Tamamlanmamış bir geri yükleme (o ana kadar taranan parçalar), siz onu tamamlayana veya listeden silene kadar uygulamanın özel depolama alanında tutulur.

## Şifreleme

Şifrelemeyi açtığınızda:

- parolanız, şifreleme anahtarını türetmek için cihazda kullanılır (PBKDF2);
- parolanız asla saklanmaz, kaydedilmez veya iletilmez;
- şifreleme ve şifre çözme tamamen cihazınızda gerçekleşir.

Parolayı unutursanız dosyayı kimse, biz de dahil, geri getiremez.

## Tanılama günlükleri

Uygulama cihazınızda bir tanılama günlüğü tutar: ne yaptığını ve karşılaştığı hataları, böylece sorunlar incelenebilir. Günlük, otomatik olarak döndürülen küçük bir dosyada saklanır ve dosyalarınızı, dosya adlarınızı veya parolalarınızı asla içermez. Hiçbir yere gönderilmez. Cihazınızdan yalnızca siz kendiniz paylaşırsanız ayrılır — **Hakkında → Tanılama günlüğü** bölümünden; günlüğü istediğiniz zaman oradan temizleyebilirsiniz.

## Üçüncü taraf hizmetleri

NFC Archiver **hiçbir üçüncü taraf hizmeti kullanmaz**: analiz, bulut depolama, uzak sunucu ve sosyal medya entegrasyonu yoktur.

## İzinler

Uygulamanın bildirdiği tüm izinler ve ne için kullanıldıkları:

**Android**

- **NFC** (`NFC`): NFC etiketlerini okumak ve yazmak için.
- **Bluetooth** (`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT`; eski Android sürümlerinde ayrıca `BLUETOOTH` ve `BLUETOOTH_ADMIN`): yalnızca size ait bir Chameleon Ultra okuyucuyu bulmak ve bağlanmak için.
- **Depolama** (`READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`): yalnızca eski Android sürümlerinde, seçtiğiniz dosyaları okumak ve geri yüklenen dosyaları kaydetmek için. Güncel sürümlerde dosyalar sistemin dosya seçicisiyle seçilir.

**iPhone**

- **NFC** (`NFCReaderUsageDescription`): NFC etiketlerini okumak ve yazmak için.
- **Bluetooth** (`NSBluetoothAlwaysUsageDescription`): yalnızca size ait bir Chameleon Ultra okuyucuya bağlanmak için.

## Bu web sitesi

Bu belge sitesi çerez kullanmaz, analiz çalıştırmaz ve üçüncü taraf yazı tipi veya betik yüklemez. Arama, tarayıcınızda yerel olarak çalışır.

## Çocukların gizliliği

Uygulama, çocuklar dahil kimseden veri toplamaz.

## Politikadaki değişiklikler

Bu politika değişirse yeni metin bu sayfada yayımlanır ve yukarıdaki tarih güncellenir.

## İletişim

Bu politikayla ilgili sorularınız için: [support@nfcarchiver.com](mailto:support@nfcarchiver.com).
