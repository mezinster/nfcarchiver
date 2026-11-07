# Przywracanie pliku

Aby przywrócić plik, zeskanuj wszystkie tagi archiwum. Kolejność nie ma znaczenia.

## 1. Zeskanuj tagi

Na ekranie głównym dotknij **Przywróć archiwum**. Otworzy się ekran **Skanuj tagi** i skanowanie się rozpocznie.

![Skanowanie tagów](../assets/screenshots/android-scan.png){ width="300" }

*Zrzut wykonano w emulatorze bez NFC, stąd ostrzeżenie. Dwa archiwa na dole przygotowano na potrzeby zrzutu.*

Przykładaj kolejno każdy tag do telefonu (na iPhonie jedno okno NFC na tag; patrz [Na iPhonie](iphone.md)):

- Nowy tag pokazuje **Znaleziono nowy fragment!** i swój numer, na przykład „Fragment 3 z 8”.
- Tag już zeskanowany pokazuje **Zduplikowany fragment** i jest pomijany. Na iPhonie okno zamyka się czerwonym wykrzyknikiem z komunikatem „Fragment 3 z 8 już zeskanowany”.

**Archiwa w toku** wymienia każde archiwum, które zacząłeś skanować, i ile jego tagów już masz (na przykład 2/4). Postęp jest zapisywany: możesz wyjść i wrócić później, aby zeskanować pozostałe tagi. Tagi różnych archiwów można mieszać; każdy trafia do swojego archiwum.

Aby usunąć niedokończone archiwum z listy, dotknij jego ✕. Ikona kosza u góry czyści całą listę.

## 2. Przywróć

Gdy zeskanujesz ostatni tag, aplikacja pokaże **Wszystkie fragmenty odebrane!**.

- **Nazwa pliku** (opcjonalnie): zostaw puste, aby użyć oryginalnej nazwy.
- Jeśli archiwum jest zaszyfrowane („To archiwum jest zaszyfrowane”), wpisz **Hasło**.

Dotknij **Przywróć archiwum**. Jeśli chcesz najpierw coś jeszcze zeskanować, **Skanuj więcej tagów** zabierze Cię z powrotem.

Tutaj można też trafić, dotykając gotowego archiwum (ze znaczkiem ✓) na liście **Archiwa w toku**.

## 3. Użyj przywróconego pliku

![Archiwum przywrócone](../assets/screenshots/android-restore-complete.png){ width="300" }

**Archiwum przywrócone!** pokazuje nazwę pliku. Dodawany jest do niej krótki fragment identyfikatora archiwum, aby pliki z różnych archiwów nigdy się nie nadpisywały. Plik jest przechowywany wewnątrz aplikacji, gdzie inne aplikacje go nie widzą. Aby z niego skorzystać:

- **Otwórz** otwiera go w aplikacji obsługującej ten typ pliku.
- **Zapisz na urządzeniu** otwiera systemowe okno zapisu (domyślnie folder Pobrane), aby zachować kopię poza aplikacją.
- **Udostępnij plik** wysyła go do innej aplikacji.

Przywrócone pliki są też widoczne w sekcji **Zarchiwizowane pliki** na ekranie głównym. Archiwum tekstu pokazuje tekst bezpośrednio, z przyciskiem do jego skopiowania.

## Jeśli coś pójdzie nie tak

- **Złe hasło**: aplikacja pisze (po angielsku) "Decryption failed: wrong password or corrupted data". Dotknij **Spróbuj innego hasła** i wpisz je ponownie.
- **Wykryto uszkodzenie danych**: fragment z któregoś tagu nie przeszedł kontroli sumy (CRC). Dotknij **Przeskanuj ponownie 1 tag(ów)** (liczba bywa różna) i zeskanuj ponownie wskazane tagi; udany odczyt zastąpi uszkodzony fragment.

Więcej w [Rozwiązywaniu problemów](troubleshooting.md).
