# Troubleshooting

## Nothing happens when I tap a tag

- **Android:** check that NFC is switched on. If the home screen says **NFC is not available**, NFC is off or the phone has none.
- **iPhone:** wait for the NFC sheet. After each tag the next sheet takes about 3 seconds to open. If scanning stopped (after Cancel or the 60-second timeout), tap **Scan more tags**.
- Move the tag slowly over the back of the phone to find the antenna, and hold it still. Thick or metal cases can block NFC.
- With a [Chameleon Ultra](chameleon.md) connected, put the tag on the Chameleon, not on the phone.
- Scanning pauses after five failed reads in a row; tap **Scan more tags** to continue.

## iPhone: the sheet closed with a cross

A cross means the tag was a duplicate (already scanned) or could not be read. A new sheet opens after about 3 seconds; present the next tag, or the same one again if it was unreadable. See [On iPhone](iphone.md).

## Tag Too Small

The tag has less room than the chunk needs. Before the first tag is written you can tap **Reconfigure** to split the archive into smaller chunks; otherwise tap **Use Different Tag**. See [Archive a file](archive.md#if-a-tag-is-too-small).

## "Tag is not writable"

The tag is locked (read-only). Use a different tag.

## "Tag does not support NDEF"

The full message is "Tag does not support NDEF. Please use a pre-formatted NDEF tag." NTAG tags must be NDEF-formatted; new NTAG tags usually are. Use another tag.

On iPhone, this is also what a Mifare Classic card shows. The iPhone's own NFC can't use these cards; use a [Chameleon Ultra](chameleon.md).

## "Couldn't read the tag"

"Couldn't read the tag — hold it still against the phone and try again." The tag moved away too early. Hold it still until the app reacts.

## "Tag does not contain valid archive data"

The tag is blank or holds something that was not written by NFC Archiver.

## "That's a … card, but this archive is configured for …"

The tag you presented is a different kind from the **NFC Tag Type** you chose. Change the tag type in the archive settings, or use the right tags.

## "This looks like a Mifare Classic card. Your phone's NFC chip can't read them."

Your Android phone can't handle Mifare Classic (its NFC chip lacks Mifare support). Use a [Chameleon Ultra](chameleon.md).

## Wrong password

"Decryption failed: wrong password or corrupted data". Tap **Try Different Password**. Upper and lower case matter (spaces at the start or end are ignored), and a forgotten password can't be recovered.

## Data Corruption Detected

A chunk failed its checksum (CRC), usually because a tag was read badly. Tap **Rescan 1 Tag(s)** (the number varies) and scan the tags the app lists again. A good read replaces the damaged chunk.

## Some tags are missing

**Archives in progress** on the scan screen shows how many tags of each archive you have (for example 5/8). Progress is saved, so you can find the missing tags and scan them later.

## Still stuck?

See [Support](support.md).
