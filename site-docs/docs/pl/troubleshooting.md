# Rozwiązywanie problemów

Niektóre komunikaty o błędach aplikacja na razie pokazuje tylko po angielsku; podajemy je tu w oryginale, z tłumaczeniem.

## Nic się nie dzieje po przyłożeniu tagu

- **Android:** sprawdź, czy NFC jest włączone. Jeśli ekran główny pokazuje **NFC jest niedostępne**, NFC jest wyłączone lub telefon go nie ma.
- **iPhone:** poczekaj na okno NFC. Po każdym tagu następne okno otwiera się po około 3 sekundach. Jeśli skanowanie się zatrzymało (po Anuluj lub 60-sekundowym limicie czasu), dotknij **Skanuj więcej tagów**.
- Powoli przesuwaj tag po tylnej ściance telefonu, aby znaleźć antenę, i trzymaj go nieruchomo. Grube lub metalowe etui mogą blokować NFC.
- Jeśli podłączony jest [Chameleon Ultra](chameleon.md), kładź tag na Chameleonie, nie na telefonie.
- Po pięciu nieudanych odczytach z rzędu skanowanie się wstrzymuje; dotknij **Skanuj więcej tagów**, aby kontynuować.

## iPhone: okno zamknęło się wykrzyknikiem

Wykrzyknik oznacza, że tag był duplikatem (już zeskanowany) albo nie dało się go odczytać. Po około 3 sekundach otworzy się nowe okno; przyłóż kolejny tag albo ten sam ponownie, jeśli się nie odczytał. Patrz [Na iPhonie](iphone.md).

## Tag za mały

Tag ma mniej miejsca, niż potrzebuje fragment. Przed zapisaniem pierwszego tagu możesz dotknąć **Przekonfiguruj**, aby podzielić archiwum na mniejsze fragmenty; w przeciwnym razie dotknij **Użyj innego tagu**. Patrz [Archiwizacja pliku](archive.md#if-a-tag-is-too-small).

## "Tag is not writable"

„Tagu nie można zapisać”: tag jest zablokowany (tylko do odczytu). Użyj innego tagu.

## "Tag does not support NDEF"

Pełny komunikat: "Tag does not support NDEF. Please use a pre-formatted NDEF tag." („Tag nie obsługuje NDEF. Użyj tagu sformatowanego pod NDEF.”) Tagi NTAG muszą być sformatowane pod NDEF; nowe zwykle już są. Użyj innego tagu.

Na iPhonie ten sam komunikat pojawia się także dla karty Mifare Classic. Wbudowane NFC iPhone'a nie obsługuje tych kart; użyj [Chameleona Ultra](chameleon.md).

## "Couldn't read the tag"

"Couldn't read the tag — hold it still against the phone and try again." („Nie udało się odczytać tagu — przytrzymaj go nieruchomo przy telefonie i spróbuj ponownie.”) Tag został zabrany za wcześnie. Trzymaj go nieruchomo, aż aplikacja zareaguje.

## "Tag does not contain valid archive data"

„Tag nie zawiera prawidłowych danych archiwum”: tag jest pusty lub zawiera coś, czego nie zapisał NFC Archiver.

## „To karta …, ale to archiwum jest skonfigurowane dla …”

Przyłożony tag jest innego rodzaju niż wybrany **Typ tagu NFC**. Zmień typ tagu w ustawieniach archiwum albo użyj właściwych tagów.

## "This looks like a Mifare Classic card. Your phone's NFC chip can't read them."

„To wygląda na kartę Mifare Classic. Chip NFC Twojego telefonu nie potrafi ich odczytać.” Twój telefon z Androidem nie obsługuje Mifare Classic (jego układ NFC nie ma obsługi Mifare). Użyj [Chameleona Ultra](chameleon.md).

## Złe hasło

"Decryption failed: wrong password or corrupted data" („Odszyfrowanie nie powiodło się: złe hasło lub uszkodzone dane”). Dotknij **Spróbuj innego hasła**. Wielkość liter ma znaczenie (spacje na początku i na końcu są ignorowane), a zapomnianego hasła nie da się odzyskać.

## Wykryto uszkodzenie danych

Fragment nie przeszedł kontroli sumy (CRC), zwykle dlatego, że tag został źle odczytany. Dotknij **Przeskanuj ponownie 1 tag(ów)** (liczba bywa różna) i zeskanuj ponownie tagi wskazane przez aplikację. Udany odczyt zastąpi uszkodzony fragment.

## Brakuje niektórych tagów

**Archiwa w toku** na ekranie skanowania pokazuje, ile tagów każdego archiwum już masz (na przykład 5/8). Postęp jest zapisywany, więc brakujące tagi możesz odnaleźć i zeskanować później.

## Nadal nie działa?

Patrz [Pomoc](support.md).
