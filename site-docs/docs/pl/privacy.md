# Polityka prywatności

*Obowiązuje angielska wersja tekstu: [Privacy policy](../../privacy/).*

**NFC Archiver** · Ostatnia aktualizacja: 7 listopada 2026

## W skrócie

NFC Archiver działa całkowicie offline. Nie zbiera i nie wysyła żadnych danych osobowych, a także nie zawiera analityki, reklam ani śledzenia. Korzysta z NFC, Bluetooth (wyłącznie do połączenia z należącym do Ciebie czytnikiem Chameleon Ultra) oraz z plików, które sam wybierasz.

## Zbieranie danych

**Nie zbieramy żadnych danych.** W szczególności:

- nie są zbierane żadne informacje osobowe;
- brak analityki użycia i śledzenia;
- raporty o awariach nie są nigdzie wysyłane;
- brak plików cookie i identyfikatorów;
- brak danych reklamowych i marketingowych.

## NFC

NFC służy wyłącznie do odczytu i zapisu danych na fizycznych tagach NFC przykładanych do telefonu. Wszystkie operacje NFC są lokalne i nic nie jest przesyłane przez sieć.

## Bluetooth

Bluetooth służy wyłącznie do połączenia z należącym do Ciebie czytnikiem Chameleon Ultra, aby aplikacja mogła za jego pomocą czytać i zapisywać karty Mifare Classic. Połączenie jest lokalne, między telefonem a czytnikiem. Dzięki niemu żadne dane nie opuszczają urządzenia, a aplikacja nie używa Bluetooth do ustalania Twojej lokalizacji.

## Pliki

Pliki wybrane do archiwizacji są przetwarzane w całości na Twoim urządzeniu. Plik jest:

- odczytywany z urządzenia za pomocą systemowego selektora plików;
- opcjonalnie kompresowany (GZIP) na urządzeniu;
- opcjonalnie szyfrowany (AES-256-GCM) na urządzeniu;
- dzielony na fragmenty i zapisywany na tagach NFC.

Dane plików nigdy nie są wysyłane na żaden serwer ani udostępniane. Odtworzone pliki trafiają do prywatnej pamięci aplikacji i opuszczają ją tylko wtedy, gdy wybierzesz Otwórz, Zapisz na urządzeniu lub Udostępnij. Niedokończone odtwarzanie (zeskanowane dotąd fragmenty) jest przechowywane w prywatnej pamięci aplikacji, dopóki go nie dokończysz lub nie usuniesz z listy.

## Szyfrowanie

Po włączeniu szyfrowania:

- hasło służy na urządzeniu do wyprowadzenia klucza szyfrującego (PBKDF2);
- hasło nigdy nie jest zapisywane, rejestrowane ani przesyłane;
- szyfrowanie i odszyfrowanie odbywają się w całości na Twoim urządzeniu.

Jeśli zapomnisz hasła, nikt nie odzyska pliku, także my.

## Dzienniki diagnostyczne

Aplikacja prowadzi krótki dziennik diagnostyczny w pamięci Twojego urządzenia. Nie jest zapisywany na żadnym serwerze i znika po zamknięciu aplikacji. Nic nie jest wysyłane, dopóki sam go nie udostępnisz, na przykład raportu z analizy karty, który zdecydujesz się udostępnić.

## Usługi stron trzecich

NFC Archiver **nie korzysta z usług stron trzecich**: bez analityki, chmury, zdalnych serwerów i integracji z mediami społecznościowymi.

## Uprawnienia

Wszystkie uprawnienia deklarowane przez aplikację i ich przeznaczenie:

**Android**

- **NFC** (`NFC`): odczyt i zapis tagów NFC.
- **Bluetooth** (`BLUETOOTH_SCAN`, `BLUETOOTH_CONNECT` oraz w starszych wersjach Androida `BLUETOOTH` i `BLUETOOTH_ADMIN`): wyłącznie do wyszukania i połączenia z należącym do Ciebie czytnikiem Chameleon Ultra.
- **Pamięć** (`READ_EXTERNAL_STORAGE`, `WRITE_EXTERNAL_STORAGE`): tylko w starszych wersjach Androida, do odczytu wybranych plików i zapisu odtworzonych. W nowszych wersjach pliki wybiera się przez systemowy selektor plików.

**iPhone**

- **NFC** (`NFCReaderUsageDescription`): odczyt i zapis tagów NFC.
- **Bluetooth** (`NSBluetoothAlwaysUsageDescription`): wyłącznie do połączenia z należącym do Ciebie czytnikiem Chameleon Ultra.

## Ta witryna

Ta witryna dokumentacji nie ustawia plików cookie, nie używa analityki i nie ładuje czcionek ani skryptów stron trzecich. Wyszukiwanie działa lokalnie w Twojej przeglądarce.

## Prywatność dzieci

Aplikacja nie zbiera danych od nikogo, także od dzieci.

## Zmiany w polityce

Jeśli polityka ulegnie zmianie, nowy tekst zostanie opublikowany na tej stronie, a data powyżej zaktualizowana.

## Kontakt

Pytania dotyczące tej polityki: [support@nfcarchiver.com](mailto:support@nfcarchiver.com).
