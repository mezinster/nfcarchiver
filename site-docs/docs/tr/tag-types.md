# Etiket türleri

NFC Archiver bu etiket türlerine yazar. Bir [dosyayı arşivlerken](archive.md) elinizdekini **NFC Etiket Türü** altında seçin.

## Kapasite

| Etiket türü | Kapasite | Etiket başına veri |
|---|---|---|
| NTAG213 | 144 bayt | 68 bayt |
| NTAG215 | 504 bayt | 428 bayt |
| NTAG216 | 888 bayt | 812 bayt |
| Mifare Classic 1K | 752 bayt | 720 bayt |

**Kapasite**, uygulamanın etiketteki kullanılabilir bellek olarak saydığı miktardır. **Etiket başına veri**, bunun dosyanıza kalan kısmıdır: her etiket ayrıca 32 baytlık bir NFAR başlığı ve sağlama toplamı taşır; NTAG etiketlerinde parça ayrıca bir NDEF kaydına sarılır (uygulama bunun için 44 bayt ayırır). Mifare Classic 1K parçayı doğrudan veri bloklarında saklar, bu yüzden yalnızca başlık düşülür. Uygulama aynı değeri arşiv tahmininde **Etiket başına veri** olarak gösterir.

## Bir dosya kabaca kaç etiket gerektirir

Sıkıştırmadan önce ve dosya adının eklediği birkaç bayt hariç:

| Dosya boyutu | NTAG213 | NTAG215 | NTAG216 | Mifare Classic 1K |
|---|---|---|---|---|
| 1 KB | 16 | 3 | 2 | 2 |
| 10 KB | 151 | 24 | 13 | 15 |
| 100 KB | 1.506 | 240 | 127 | 143 |

Şifreleme etiket başına değil, toplamda 44 bayt ekler. NFC etiketleri küçüktür: arşivler en çok metin, anahtarlar, yapılandırma dosyaları ya da küçük belgeler gibi küçük dosyalara uygundur. Bir arşivde en fazla 65.535 parça olabilir.

Gerçek bir etiket türünün vaat ettiğinden daha az yer bildirirse uygulama, ilk etiket yazılmadan önce arşivi yeniden yapılandırmayı önerir (bkz. [Bir etiket çok küçükse](archive.md#if-a-tag-is-too-small)).

Uygulamadaki listede ayrıca MIFARE Ultralight (48 bayt, bir arşiv parçası için fazla küçük), MIFARE Ultralight C (144 bayt) ve Generic 1KB (1024 bayt) bulunur.

## Hangi okuyucu neyi destekler

| | NTAG213/215/216 | Mifare Classic 1K |
|---|---|---|
| iPhone'un kendi NFC'si | Evet | Hayır |
| Android telefonun kendi NFC'si | Evet | Yalnızca telefonun NFC çipi Mifare Classic'i destekliyorsa |
| [Chameleon Ultra](chameleon.md) (iPhone ya da Android ile) | Evet | Evet |

Uygulama Mifare Classic 1K'yi yalnızca etkin okuyucu ona yazabildiğinde sunar. Mifare Classic 1K seçiliyken Chameleon bağlantısını keserseniz ve telefonunuz onu kullanamıyorsa seçim NTAG216'ya döner.
