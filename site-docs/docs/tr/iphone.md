# iPhone'da

iPhone'un kendi NFC'si **NTAG213, NTAG215 ve NTAG216** etiketlerine yazar ve onları okur. Mifare Classic için bir [Chameleon Ultra](chameleon.md) gerekir (aşağıya bakın).

## Her etiket için bir NFC penceresi

Yazarken ve tararken iOS ekranın altında kendi NFC penceresini gösterir. NFC Archiver **her etiket için yeni bir pencere** açar:

1. iPhone'un üst kısmını etikete tutun. Pencere etiketi okur (ya da ona yazar) ve kapanır.
2. Pencerenin nasıl kapandığı ne olduğunu gösterir:
    - **onay işareti**: etiket okundu (ya da yazıldı) ve parçası yeni;
    - **çarpı**: yinelenen bir etiket (zaten taradığınız bir parça) ya da okunamayan bir etiket.
3. Yaklaşık **3 saniye** bekleyin. Sonraki pencere kendiliğinden açılır; ardından sonraki etiketi tutun.

Telefonun üzerinde duran bir etiket yalnızca bir kez okunur, bu yüzden onu aceleyle çekmeniz gerekmez.

Pencere açıkken uygulamayı örter; bu yüzden onay işareti ya da çarpı ve titreşim sizin geri bildiriminizdir. Ayrıntıları uygulama pencere kapanınca gösterir.

## Durdurma ve devam etme

- Penceredeki **İptal** taramayı durdurur. Devam etmek için tarama ekranında **Daha fazla etiket tara**'ya dokunun. Önceden taranan parçalar saklanır.
- Etiket tutulmazsa pencere **60 saniye sonra zaman aşımına uğrar**. Bu da taramayı durdurur; devam etmek için **Daha fazla etiket tara**'ya dokunun.
- **Ekrandan çıkmak** (geri tuşu ya da geri kaydırma) taramayı ya da yazmayı durdurur.

Yazarken İptal ya da zaman aşımı sizi hatasız olarak geçerli etiketin "hazır" durumuna döndürür: yeniden **Etikete Yaz**'a dokunun.

## Mifare Classic

iPhone'un kendi NFC'siyle Mifare Classic **imkânsızdır**: Core NFC bu kartların kullandığı CRYPTO1 şifresini desteklemez, bu yüzden uygulama iPhone'da telefon NFC'siyle Mifare Classic 1K sunmaz. Bluetooth ile bağlı bir [Chameleon Ultra](chameleon.md) ile bu mümkündür, çünkü şifrelemeyi okuyucunun kendisi yapar. Bu durumda Mifare Classic 1K etiket türü listesinde görünür.

## Sonraki adımlar

- [Dosya arşivleme](archive.md)
- [Dosya geri yükleme](restore.md)
- [Sorun giderme](troubleshooting.md)
