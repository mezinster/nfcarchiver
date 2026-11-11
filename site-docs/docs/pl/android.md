# Na Androidzie

Telefon z Androidem i NFC zapisuje i odczytuje tagi **NTAG213, NTAG215 i NTAG216** bezpośrednio. Może też bezpośrednio zapisywać i odczytywać **Mifare Classic 1K**, ale tylko jeśli jego układ NFC obsługuje Mifare Classic (funkcja NXP Mifare). Nie każdy telefon to potrafi: wielu układom NFC innych producentów jej brakuje.

Aplikacja sprawdza to za Ciebie. Jeśli Twój telefon nie obsługuje Mifare Classic, **Mifare Classic 1K** po prostu nie ma na liście typów tagów. [Chameleon Ultra](chameleon.md) dodaje go na każdym telefonie.

![Ekran główny](../assets/screenshots/android-home.png){ width="300" }

*Ekran główny (zrzuty ekranu po angielsku). Zrzut wykonano w emulatorze bez NFC, stąd ostrzeżenie „NFC jest niedostępne”.*

## Zanim zaczniesz

- **Włącz NFC** w ustawieniach telefonu. Jeśli NFC jest wyłączone (lub go nie ma), ekran główny pokazuje **NFC jest niedostępne**.
- **Znajdź antenę.** Położenie anteny NFC zależy od telefonu; w wielu modelach jest z tyłu, bliżej góry. Jeśli nic się nie dzieje, powoli przesuwaj tag po tylnej ściance telefonu.
- Trzymaj tag nieruchomo, aż aplikacja zareaguje. Tag zabrany w trakcie zapisu lub odczytu to najczęstsza przyczyna nieudanego tagu.

## Jak to działa na Androidzie

Na Androidzie nie ma okna systemowego: postęp pokazuje ekran samej aplikacji.

- Przy **zapisie** dotknij **Zapisz na tag**, a potem przyłóż tag do telefonu. **Tag zapisany!** potwierdza zapis. Zabierz tag i dotknij ponownie **Zapisz na tag** dla kolejnego.
- Przy **skanowaniu** przykładaj tagi po kolei. Każdy nowy pokazuje **Znaleziono nowy fragment!**; tag już zeskanowany pokazuje **Zduplikowany fragment**.

Jeśli przyłożysz kartę Mifare Classic do telefonu bez jej obsługi, aplikacja poinformuje (na razie po angielsku): "This looks like a Mifare Classic card. Your phone's NFC chip can't read them." („To wygląda na kartę Mifare Classic. Chip NFC Twojego telefonu nie potrafi ich odczytać.”)

## Udostępnianie do NFC Archiver { #share-into-nfc-archiver }

W Galerii, Zdjęciach lub Plikach dotknij **Udostępnij**, potem **NFC Archiver**. Zdjęcie otwiera **Optymalizuj zdjęcie**; każdy inny plik otwiera **Ustawienia archiwum**. Jeśli udostępnisz kilka elementów, używany jest tylko pierwszy (aplikacja o tym informuje). Jeśli jesteś w trakcie zapisywania archiwum, aplikacja zapyta **Rozpocząć nowe archiwum?**, zanim je odrzuci. Udostępnianie zwykłego tekstu (np. linku) nie jest obsługiwane i pokazuje komunikat „Nie udało się odczytać udostępnionego elementu.” O optymalizatorze zobacz [Archiwizacja zdjęcia](archive.md#archiving-a-photo).

## Dalej

- [Archiwizacja pliku](archive.md)
- [Przywracanie pliku](restore.md)
- [Typy tagów](tag-types.md)
