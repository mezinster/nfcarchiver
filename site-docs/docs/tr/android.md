# Android'de

NFC'li bir Android telefon **NTAG213, NTAG215 ve NTAG216** etiketlerine doğrudan yazar ve onları okur. **Mifare Classic 1K** kartlarını da doğrudan yazıp okuyabilir, ancak yalnızca NFC çipi Mifare Classic'i (NXP'nin Mifare özelliği) destekliyorsa. Her telefon desteklemez: diğer üreticilerin birçok NFC çipinde bu özellik yoktur.

Uygulama bunu sizin için denetler. Telefonunuz Mifare Classic kullanamıyorsa **Mifare Classic 1K** etiket türü listesinde yer almaz. Bir [Chameleon Ultra](chameleon.md) onu her telefona ekler.

![Ana ekran](../assets/screenshots/android-home.png){ width="300" }

*Ana ekran (ekran görüntüleri İngilizcedir). Görüntü NFC'si olmayan bir emülatörde alındı, "NFC is not available" (NFC kullanılamıyor) uyarısı bu yüzden görünüyor.*

## Başlamadan önce

- Telefonun ayarlarından **NFC'yi açın**. NFC kapalıysa (ya da telefonda yoksa) ana ekranda **NFC kullanılamıyor** yazar.
- **Anteni bulun.** NFC anteninin yeri telefona göre değişir; birçok telefonda arka yüzde, üste yakındır. Bir şey olmazsa etiketi telefonun arkasında yavaşça gezdirin.
- Uygulama tepki verene kadar etiketi sabit tutun. Yazma ya da okuma sırasında çekilen etiket, başarısız etiketlerin en yaygın nedenidir.

## Android'de nasıl çalışır

Android'de sistem penceresi yoktur: ilerlemeyi uygulamanın kendi ekranı gösterir.

- **Yazarken** **Etikete Yaz**'a dokunun, ardından etiketi telefona tutun. **Etiket Yazıldı!** bunu onaylar. Etiketi çekin, sonraki için yeniden **Etikete Yaz**'a dokunun.
- **Tararken** etiketleri sırayla tutun. Her yeni etiket **Yeni parça bulundu!** gösterir; zaten taradığınız bir etiket **Yinelenen parça** gösterir.

Mifare desteği olmayan bir telefona Mifare Classic kart tutarsanız uygulama (şimdilik İngilizce olarak) şunu söyler: "This looks like a Mifare Classic card. Your phone's NFC chip can't read them." ("Bu bir Mifare Classic kart gibi görünüyor. Telefonunuzun NFC çipi bunları okuyamaz.")

## Sonraki adımlar

- [Dosya arşivleme](archive.md)
- [Dosya geri yükleme](restore.md)
- [Etiket türleri](tag-types.md)
