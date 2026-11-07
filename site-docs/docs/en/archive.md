# Archive a file

Archiving splits a file into chunks and writes one chunk to each tag. You need as many blank (or reusable) tags as the app tells you.

## 1. Pick a file

On the home screen tap **Create Archive**. Choose **File** and tap to pick a file with the system file picker, or choose **Text** to type a short text instead. Then tap **Configure Archive**.

## 2. Choose the settings

![Archive settings: tag types](../assets/screenshots/android-archive-settings.png){ width="300" }
![Archive settings: options and estimate](../assets/screenshots/android-archive-estimate.png){ width="300" }

- **NFC Tag Type**: the kind of tags you will write. NTAG216 is selected by default. See [Tag types](tag-types.md) for how much each holds. Mifare Classic 1K is only listed when your reader can write it (an Android phone with Mifare support, or a [Chameleon Ultra](chameleon.md)).
- **Enable Compression** (optional): GZIP compression. It is only applied if it actually makes the data smaller; already-compressed files such as photos, videos or ZIP files hardly shrink.
- **Enable Encryption** (optional): protects the archive with AES-256-GCM. Enter a **Password**. The password is not stored anywhere: without it the archive cannot be restored, so don't lose it.

The **Archive Estimate** at the bottom shows how many tags you need (**Tags needed**) and how many bytes go on each (**Payload per tag**). It is an estimate: compression is guessed before it runs.

Tap **Start Archiving**.

## 3. Write the tags one by one

![Writing to tags](../assets/screenshots/android-write-progress.png){ width="300" }

For each tag:

1. Tap **Write to Tag**.
2. Hold a tag against the phone (on iPhone, when the NFC sheet appears; see [On iPhone](iphone.md)).
3. Wait for **Tag Written!**, then take the tag away.

The progress bar counts the tags written. When the last one is done you see **Archive Complete!**.

Tags can later be scanned in any order, so you don't need to number them. Keep them together, though: every tag is needed to restore the file.

!!! warning "Skip this tag"
    **Skip this tag** moves on to the next chunk *without writing* the current one. An archive with a skipped chunk can't be restored: a skipped chunk can't be written later. To get a restorable archive you have to archive the file again from the start.

## If a tag is too small { #if-a-tag-is-too-small }

Real tags sometimes offer a little less space than their type promises. If a tag can't hold the chunk, the app shows **Tag Too Small** with the space the tag has and the space the chunk needs:

- If no tag has been written yet, you can tap **Reconfigure**: the app splits the data into smaller chunks that fit this tag, and tells you how many tags are now needed.
- Otherwise, or if you prefer, tap **Use Different Tag** and present a bigger tag.

Once a tag has been written, the archive can no longer be reconfigured.

If you present a different kind of tag from the one you chose (for example a Mifare Classic card when NTAG216 is selected), the app says so; go back and change the **NFC Tag Type**.
