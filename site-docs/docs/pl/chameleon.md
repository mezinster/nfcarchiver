# Czytnik Chameleon

[Chameleon Ultra](https://github.com/RfidResearchGroup/ChameleonUltra) to mały, kieszonkowy czytnik i emulator NFC. NFC Archiver może go używać przez **Bluetooth** zamiast wbudowanego NFC telefonu, zarówno na iPhonie, jak i na Androidzie.

## Po co go używać

- **Mifare Classic 1K na każdym telefonie.** Karty Mifare Classic wymagają szyfru CRYPTO1. Chameleon wykonuje go we własnym układzie, więc działa niezależnie od telefonu.
- **Na iPhonie to jedyny sposób na Mifare Classic.** Wbudowane NFC iPhone'a w ogóle nie potrafi odczytywać ani zapisywać tych kart.
- **Badanie karty.** Z podłączonym Chameleonem **Zbadaj kartę** pokazuje zawartość karty blok po bloku. Wbudowane NFC telefonu nie ma bezpośredniego dostępu do kart, więc wymaga to Chameleona.

## Łączenie

1. Włącz Chameleona i trzymaj go blisko telefonu.
2. Włącz Bluetooth.
3. Na ekranie głównym dotknij **ikony czytnika** na górnym pasku (symbol NFC, gdy używane jest NFC telefonu). Otworzy się ekran **Czytnik**.
4. Dotknij **Szukaj**, a potem swojego Chameleona na liście.

Za pierwszym razem telefon poprosi o uprawnienie Bluetooth. Aplikacja używa Bluetooth tylko do komunikacji z Twoim Chameleonem; na Androidzie nie prosi o dostęp do lokalizacji.

Po połączeniu ikona czytnika pokazuje symbol Bluetooth, a **Utwórz archiwum** i **Przywróć archiwum** używają Chameleona: kładź tagi na Chameleonie, nie na telefonie. Na iPhonie w tym trybie nie pojawia się okno NFC. Na liście typów tagów pojawia się **Mifare Classic 1K**.

Aby wrócić do wbudowanego NFC, otwórz ekran **Czytnik** i dotknij **Rozłącz**.

## Jeśli nie zostaje znaleziony

- „Bluetooth jest wyłączony. Włącz go, aby użyć Chameleona.”: włącz Bluetooth.
- „Do znalezienia Chameleona wymagane jest uprawnienie Bluetooth.”: zezwól NFC Archiver na Bluetooth w ustawieniach telefonu.
- Lista ciągle pokazuje „Szukanie urządzeń Chameleon…”: wybudź Chameleona i przybliż go. Słaby sygnał Bluetooth spowalnia też każdą operację.
- „Nie udało się połączyć z Chameleonem.”: wyłącz i włącz Chameleona, a potem dotknij ponownie **Szukaj**.

Więcej szczegółów, w tym o badaniu kart, znajdziesz w [CHAMELEON.md na GitHubie](https://github.com/mezinster/nfcarchiver/blob/master/docs/CHAMELEON.md) (po angielsku).
