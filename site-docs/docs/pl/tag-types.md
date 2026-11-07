# Typy tagów

NFC Archiver zapisuje tagi tych typów. Wybierz posiadany w polu **Typ tagu NFC** podczas [archiwizacji pliku](archive.md).

## Pojemność

| Typ tagu | Pojemność | Dane na tag |
|---|---|---|
| NTAG213 | 144 bajty | 68 bajtów |
| NTAG215 | 504 bajty | 428 bajtów |
| NTAG216 | 888 bajtów | 812 bajtów |
| Mifare Classic 1K | 752 bajty | 720 bajtów |

**Pojemność** to pamięć tagu, którą aplikacja uznaje za użyteczną. **Dane na tag** to część, która zostaje na Twój plik: każdy tag niesie też 32-bajtowy nagłówek NFAR z sumą kontrolną, a na tagach NTAG fragment jest dodatkowo opakowany w rekord NDEF (aplikacja rezerwuje na niego 44 bajty). Mifare Classic 1K przechowuje fragment bezpośrednio w blokach danych, więc odejmowany jest tylko nagłówek. Tę samą wartość aplikacja pokazuje jako **Dane na tag** w szacunku archiwum.

## Ile tagów potrzebuje plik, w przybliżeniu

Bez kompresji i bez kilku bajtów, które dodaje nazwa pliku:

| Rozmiar pliku | NTAG213 | NTAG215 | NTAG216 | Mifare Classic 1K |
|---|---|---|---|---|
| 1 KB | 16 | 3 | 2 | 2 |
| 10 KB | 151 | 24 | 13 | 15 |
| 100 KB | 1506 | 240 | 127 | 143 |

Szyfrowanie dodaje łącznie 44 bajty, a nie na każdy tag. Tagi NFC są małe: archiwa najlepiej nadają się do małych plików, takich jak tekst, klucze, pliki konfiguracyjne czy niewielkie dokumenty. Archiwum może mieć najwyżej 65 535 fragmentów.

Jeśli prawdziwy tag zgłasza mniej miejsca niż jego typ, aplikacja zaproponuje przekonfigurowanie archiwum przed zapisaniem pierwszego tagu (patrz [Jeśli tag jest za mały](archive.md#if-a-tag-is-too-small)).

Lista w aplikacji zawiera też MIFARE Ultralight (48 bajtów, za mało na fragment archiwum), MIFARE Ultralight C (144 bajty) i Generic 1KB (1024 bajty).

## Który czytnik co obsługuje

| | NTAG213/215/216 | Mifare Classic 1K |
|---|---|---|
| Wbudowane NFC iPhone'a | Tak | Nie |
| Wbudowane NFC telefonu z Androidem | Tak | Tylko jeśli układ NFC telefonu obsługuje Mifare Classic |
| [Chameleon Ultra](chameleon.md) (z iPhone'em lub Androidem) | Tak | Tak |

Aplikacja oferuje Mifare Classic 1K tylko wtedy, gdy aktywny czytnik potrafi go zapisać. Jeśli odłączysz Chameleona przy wybranym Mifare Classic 1K, a Twój telefon go nie obsługuje, wybór wróci do NTAG216.
