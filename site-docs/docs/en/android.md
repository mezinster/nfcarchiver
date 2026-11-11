# On Android

An Android phone with NFC writes and reads **NTAG213, NTAG215 and NTAG216** tags directly. It can also write and read **Mifare Classic 1K** directly, but only if its NFC chip supports Mifare Classic (NXP's Mifare feature). Not all phones do: many NFC chips from other makers lack it.

The app checks this for you. If your phone can't do Mifare Classic, **Mifare Classic 1K** is simply not in the tag type list. A [Chameleon Ultra](chameleon.md) adds it on any phone.

![The home screen](../assets/screenshots/android-home.png){ width="300" }

*The home screen. This screenshot was taken on an emulator, which has no NFC, hence the "NFC is not available" warning.*

## Before you start

- **Switch NFC on** in the phone's settings. If NFC is off (or the phone has none), the home screen shows **NFC is not available**.
- **Find the antenna.** Where the NFC antenna sits depends on the phone; on many phones it is on the back, towards the top. If nothing happens, move the tag slowly over the back of the phone.
- Hold the tag still until the app reacts. Pulling it away mid-write or mid-read is the most common cause of a failed tag.

## How it works on Android

There is no system sheet on Android: the app's own screen shows the progress.

- When **writing**, tap **Write to Tag**, then hold the tag to the phone. **Tag Written!** confirms it. Remove the tag, then tap **Write to Tag** again for the next one.
- When **scanning**, keep presenting tags. Each new one shows **New chunk found!**; a tag you already scanned shows **Duplicate chunk**.

If you tap a Mifare Classic card on a phone without Mifare support, the app says: "This looks like a Mifare Classic card. Your phone's NFC chip can't read them."

## Share into NFC Archiver { #share-into-nfc-archiver }

In Gallery, Photos or Files, tap **Share**, then **NFC Archiver**. A photo opens **Optimise photo**; any other file opens **Archive Settings**. If you share several items, only the first is used (the app tells you). If you are in the middle of writing an archive, the app asks **Start a new archive?** before discarding it. Sharing plain text (for example a link) is not supported and shows "The shared item couldn't be read." See [Archiving a photo](archive.md#archiving-a-photo) for the optimiser.

## Next

- [Archive a file](archive.md)
- [Restore a file](restore.md)
- [Tag types](tag-types.md)
