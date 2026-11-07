# Sorun giderme

Bazı hata mesajlarını uygulama şimdilik yalnızca İngilizce gösteriyor; burada oldukları gibi, çevirileriyle birlikte verilmiştir.

## Bir etiketi tuttuğumda hiçbir şey olmuyor

- **Android:** NFC'nin açık olduğunu denetleyin. Ana ekranda **NFC kullanılamıyor** yazıyorsa NFC kapalıdır ya da telefonda yoktur.
- **iPhone:** NFC penceresini bekleyin. Her etiketten sonra sonraki pencerenin açılması yaklaşık 3 saniye sürer. Tarama durduysa (İptal ya da 60 saniyelik zaman aşımından sonra) **Daha fazla etiket tara**'ya dokunun.
- Anteni bulmak için etiketi telefonun arkasında yavaşça gezdirin ve sabit tutun. Kalın ya da metal kılıflar NFC'yi engelleyebilir.
- Bir [Chameleon Ultra](chameleon.md) bağlıysa etiketi telefona değil Chameleon'a koyun.
- Art arda beş başarısız okumadan sonra tarama duraklar; devam etmek için **Daha fazla etiket tara**'ya dokunun.

## iPhone: pencere bir ünlem işaretiyle kapandı

Ünlem işareti, etiketin yinelenen (zaten taranmış) ya da okunamayan bir etiket olduğu anlamına gelir. Yaklaşık 3 saniye sonra yeni bir pencere açılır; sonraki etiketi ya da okunamadıysa aynısını yeniden tutun. Bkz. [iPhone'da](iphone.md).

## Etiket Çok Küçük

Etiketin parçanın ihtiyacından daha az yeri var. İlk etiket yazılmadan önce arşivi daha küçük parçalara bölmek için **Yeniden Yapılandır**'a dokunabilirsiniz; aksi hâlde **Farklı Etiket Kullan**'a dokunun. Bkz. [Dosya arşivleme](archive.md#if-a-tag-is-too-small).

## "Tag is not writable"

"Etiket yazılabilir değil": etiket kilitli (salt okunur). Farklı bir etiket kullanın.

## "Tag does not support NDEF"

Mesajın tamamı: "Tag does not support NDEF. Please use a pre-formatted NDEF tag." ("Etiket NDEF desteklemiyor. Lütfen NDEF için biçimlendirilmiş bir etiket kullanın.") NTAG etiketleri NDEF biçimli olmalıdır; yeni NTAG etiketleri genellikle öyledir. Başka bir etiket kullanın.

iPhone'da bir Mifare Classic kart da bu mesajı gösterir. iPhone'un kendi NFC'si bu kartları kullanamaz; bir [Chameleon Ultra](chameleon.md) kullanın.

## "Couldn't read the tag"

"Couldn't read the tag — hold it still against the phone and try again." ("Etiket okunamadı — telefona sabit tutun ve yeniden deneyin.") Etiket çok erken çekildi. Uygulama tepki verene kadar sabit tutun.

## "Tag does not contain valid archive data"

"Etikette geçerli arşiv verisi yok": etiket boş ya da NFC Archiver tarafından yazılmamış bir şey içeriyor.

## "Bu bir … kart, ancak bu arşiv … için yapılandırılmış"

Tuttuğunuz etiket, seçtiğiniz **NFC Etiket Türü**'nden farklı türde. Arşiv ayarlarında etiket türünü değiştirin ya da doğru etiketleri kullanın.

## "This looks like a Mifare Classic card. Your phone's NFC chip can't read them."

"Bu bir Mifare Classic kart gibi görünüyor. Telefonunuzun NFC çipi bunları okuyamaz." Android telefonunuz Mifare Classic kullanamıyor (NFC çipinde Mifare desteği yok). Bir [Chameleon Ultra](chameleon.md) kullanın.

## Yanlış şifre

"Decryption failed: wrong password or corrupted data" ("Şifre çözme başarısız: yanlış şifre ya da bozuk veri"). **Farklı Şifre Dene**'ye dokunun. Büyük ve küçük harf fark eder (baştaki ve sondaki boşluklar yok sayılır) ve unutulan bir şifre kurtarılamaz.

## Veri Bozulması Tespit Edildi

Bir parça sağlama toplamı (CRC) denetiminden geçemedi; genellikle bir etiket kötü okunduğu için. **1 Etiketi Yeniden Tara**'ya (sayı değişir) dokunun ve uygulamanın listelediği etiketleri yeniden tarayın. İyi bir okuma bozuk parçanın yerini alır.

## Bazı etiketler eksik

Tarama ekranındaki **Devam eden arşivler**, her arşivin kaç etiketinin elinizde olduğunu gösterir (örneğin 5/8). İlerleme kaydedilir; eksik etiketleri bulup daha sonra tarayabilirsiniz.

## Hâlâ çözülmedi mi?

Bkz. [Destek](support.md).
