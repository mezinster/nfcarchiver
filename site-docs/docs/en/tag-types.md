# Tag types

NFC Archiver writes to these tag types. Choose the one you have under **NFC Tag Type** when you [archive a file](archive.md).

## Capacity

| Tag type | Capacity | Payload per tag |
|---|---|---|
| NTAG213 | 144 bytes | 68 bytes |
| NTAG215 | 504 bytes | 428 bytes |
| NTAG216 | 888 bytes | 812 bytes |
| Mifare Classic 1K | 752 bytes | 720 bytes |

**Capacity** is what the app counts as usable memory on the tag. **Payload per tag** is the part of it left for your file: every tag also carries a 32-byte NFAR header and checksum, and NTAG tags also wrap the chunk in an NDEF record (the app reserves 44 bytes for it). Mifare Classic 1K stores the chunk directly in its data blocks, so only the header comes off. The app shows the same figure as **Payload per tag** in the archive estimate.

## How many tags a file needs, roughly

Before compression, and leaving out the few bytes the file name adds:

| File size | NTAG213 | NTAG215 | NTAG216 | Mifare Classic 1K |
|---|---|---|---|---|
| 1 KB | 16 | 3 | 2 | 2 |
| 10 KB | 151 | 24 | 13 | 15 |
| 100 KB | 1,506 | 240 | 127 | 143 |

Encryption adds 44 bytes in total, not per tag. NFC tags are small: archives are best suited to small files such as text, keys, configuration files or small documents. An archive can have at most 65,535 chunks.

If a real tag reports less space than its type, the app offers to reconfigure the archive before the first tag is written (see [If a tag is too small](archive.md#if-a-tag-is-too-small)).

The list in the app also contains MIFARE Ultralight (48 bytes, too small to hold an archive chunk), MIFARE Ultralight C (144 bytes) and Generic 1KB (1024 bytes).

## Which reader supports which

| | NTAG213/215/216 | Mifare Classic 1K |
|---|---|---|
| iPhone's own NFC | Yes | No |
| Android phone's own NFC | Yes | Only if the phone's NFC chip supports Mifare Classic |
| [Chameleon Ultra](chameleon.md) (with iPhone or Android) | Yes | Yes |

The app offers Mifare Classic 1K only when the active reader can write it. If you disconnect a Chameleon while Mifare Classic 1K is selected and your phone can't handle it, the selection goes back to NTAG216.
