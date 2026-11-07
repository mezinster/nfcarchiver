# Chameleon okuyucu

[Chameleon Ultra](https://github.com/RfidResearchGroup/ChameleonUltra), cebe sığan küçük bir NFC okuyucu ve emülatördür. NFC Archiver, telefonun kendi NFC'si yerine onu **Bluetooth** üzerinden kullanabilir; hem iPhone'da hem Android'de.

## Neden kullanılır

- **Her telefonda Mifare Classic 1K.** Mifare Classic kartları CRYPTO1 şifresine ihtiyaç duyar. Chameleon bunu kendi çipinde yapar, bu yüzden hangi telefonunuz olursa olsun çalışır.
- **iPhone'da Mifare Classic kullanmanın tek yolu budur.** iPhone'un kendi NFC'si bu kartları hiç okuyamaz ve yazamaz.
- **Kart inceleme.** Chameleon bağlıyken **Kartı incele**, bir kartta ne olduğunu blok blok gösterir. Telefonun kendi NFC'sinin kartlara ham erişimi yoktur, bu yüzden bunun için Chameleon gerekir.

## Bağlanma

1. Chameleon'u açın ve telefonun yakınında tutun.
2. Bluetooth'u açın.
3. Ana ekranda üst çubuktaki **okuyucu simgesine** dokunun (telefonun kendi NFC'si kullanılırken bir NFC simgesi). **Okuyucu** ekranı açılır.
4. **Ara**'ya dokunun, ardından listede Chameleon'unuza dokunun.

İlk seferde telefon Bluetooth izni ister. Uygulama Bluetooth'u yalnızca Chameleon'unuzla konuşmak için kullanır; Android'de konumunuzu istemez.

Bağlandıktan sonra okuyucu simgesi bir Bluetooth simgesi gösterir ve **Arşiv Oluştur** ile **Arşivi Geri Yükle** Chameleon'u kullanır: etiketleri telefona değil Chameleon'a koyun. iPhone'da bu modda NFC penceresi görünmez. Etiket türü listesinde **Mifare Classic 1K** görünür.

Telefonun kendi NFC'sine dönmek için **Okuyucu** ekranını açın ve **Bağlantıyı kes**'e dokunun.

## Bulunamazsa

- "Bluetooth kapalı. Chameleon kullanmak için açın.": Bluetooth'u açın.
- "Chameleon bulmak için Bluetooth izni gerekir.": telefonun ayarlarında NFC Archiver için Bluetooth iznini verin.
- Liste "Chameleon aranıyor…" durumunda kalıyorsa: Chameleon'u uyandırın ve yaklaştırın. Zayıf bir Bluetooth sinyali her işlemi de yavaşlatır.
- "Chameleon’a bağlanılamadı.": Chameleon'u kapatıp açın, sonra yeniden **Ara**'ya dokunun.

Kart inceleyici dahil daha fazla ayrıntı [GitHub'daki CHAMELEON.md](https://github.com/mezinster/nfcarchiver/blob/master/docs/CHAMELEON.md) dosyasındadır (İngilizce).
