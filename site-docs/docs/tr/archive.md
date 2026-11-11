# Dosya arşivleme

Arşivleme bir dosyayı parçalara böler ve her etikete bir parça yazar. Uygulamanın söylediği kadar boş (ya da yeniden yazılabilir) etikete ihtiyacınız olur.

## 1. Dosya seçin

Ana ekranda **Arşiv Oluştur**'a dokunun. **Dosya**'yı seçip sistem dosya seçicisiyle bir dosya seçmek için dokunun ya da kısa bir metin yazmak için **Metin**'i seçin. Ardından **Arşivi Yapılandır**'a dokunun.

## Fotoğraf arşivleme { #archiving-a-photo }

Arşiv oluşturma ekranında **Fotoğraf seç**'e dokunun veya Fotoğraflar, Galeri ya da Dosyalar'dan bir fotoğrafı NFC Archiver'a paylaşın (fotoğraf olmayan bir dosya doğrudan arşiv ayarlarını açar). Birden fazla öğe paylaşırsanız yalnızca ilki kullanılır. iPhone'da paylaşımdan sonra uygulama kendiliğinden açılmazsa uygulamayı açın, fotoğraf alınır.

**Fotoğrafı optimize et** ekranı fotoğrafı etiketlerinize sığacak şekilde küçültür. **Kullanılacak etiket** altında sığan en iyi kalite otomatik bulunur; sayıyı kendiniz seçmek için **Manuel**'e dokunun (geri dönmek için **Otomatiğe dön**). Fotoğrafı olduğu gibi arşivlemek için **Atla (orijinali koru)**, sonucu kabul etmek için **Devam**'a dokunun.

Optimize edilen fotoğraftan konum ve kamera bilgileri kaldırılır.

## 2. Ayarları seçin

![Arşiv ayarları: etiket türleri](../assets/screenshots/android-archive-settings.png){ width="300" }
![Arşiv ayarları: seçenekler ve tahmin](../assets/screenshots/android-archive-estimate.png){ width="300" }

- **NFC Etiket Türü**: yazacağınız etiketlerin türü. Varsayılan olarak NTAG216 seçilidir. Her birinin ne kadar tuttuğu için [Etiket türleri](tag-types.md) sayfasına bakın. Mifare Classic 1K yalnızca okuyucunuz ona yazabiliyorsa listelenir (Mifare destekli bir Android telefon ya da bir [Chameleon Ultra](chameleon.md)).
- **Sıkıştırmayı Etkinleştir** (isteğe bağlı): GZIP sıkıştırması. Yalnızca veriyi gerçekten küçültüyorsa uygulanır; fotoğraf, video ya da ZIP gibi zaten sıkıştırılmış dosyalar pek küçülmez.
- **Şifrelemeyi Etkinleştir** (isteğe bağlı): arşivi AES-256-GCM ile korur. Bir **Şifre** girin. Şifre hiçbir yerde saklanmaz: o olmadan arşiv geri yüklenemez, bu yüzden kaybetmeyin.

Alttaki **Arşiv Tahmini** kaç etikete ihtiyacınız olduğunu (**Gereken etiket sayısı**) ve her birine kaç bayt gideceğini (**Etiket başına veri**) gösterir. Bu bir tahmindir: sıkıştırma, çalışmadan önce kestirilir.

**Arşivlemeyi Başlat**'a dokunun.

## 3. Etiketleri tek tek yazın

![Etiketlere yazma](../assets/screenshots/android-write-progress.png){ width="300" }

Her etiket için:

1. **Etikete Yaz**'a dokunun.
2. Bir etiketi telefona tutun (iPhone'da NFC penceresi göründüğünde; bkz. [iPhone'da](iphone.md)).
3. **Etiket Yazıldı!** mesajını bekleyin, ardından etiketi çekin.

İlerleme çubuğu yazılan etiketleri sayar. Sonuncusu bitince **Arşivleme Tamamlandı!** görürsünüz.

Etiketler daha sonra herhangi bir sırayla taranabilir, bu yüzden numaralandırmanız gerekmez. Yine de onları bir arada tutun: dosyayı geri yüklemek için her etiket gereklidir.

!!! warning "Bu etiketi atla"
    **Bu etiketi atla**, geçerli parçayı *yazmadan* sonraki parçaya geçer. Atlanmış parçası olan bir arşiv geri yüklenemez: atlanan parça sonradan yazılamaz. Geri yüklenebilir bir arşiv için dosyayı baştan yeniden arşivlemeniz gerekir.

## Bir etiket çok küçükse { #if-a-tag-is-too-small }

Gerçek etiketler bazen türlerinin vaat ettiğinden biraz daha az yer sunar. Bir etiket parçayı alamıyorsa uygulama, etiketin sahip olduğu ve parçanın ihtiyaç duyduğu alanla birlikte **Etiket Çok Küçük** gösterir:

- Henüz hiçbir etiket yazılmadıysa **Yeniden Yapılandır**'a dokunabilirsiniz: uygulama veriyi bu etikete sığan daha küçük parçalara böler ve artık kaç etiket gerektiğini söyler.
- Aksi hâlde ya da tercih ederseniz **Farklı Etiket Kullan**'a dokunun ve daha büyük bir etiket tutun.

Bir etiket yazıldıktan sonra arşiv artık yeniden yapılandırılamaz.

Seçtiğinizden farklı türde bir etiket tutarsanız (örneğin NTAG216 seçiliyken bir Mifare Classic kart) uygulama bunu söyler; geri dönüp **NFC Etiket Türü**'nü değiştirin.
