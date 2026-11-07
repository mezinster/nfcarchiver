# Restore a file

To restore, scan all the tags of an archive. The order does not matter.

## 1. Scan the tags

On the home screen tap **Restore Archive**. The **Scan Tags** screen opens and scanning starts.

![Scanning tags](../assets/screenshots/android-scan.png){ width="300" }

*Taken on an emulator without NFC, hence the warning. The two archives below were prepared for the screenshot.*

Hold each tag against the phone in turn (on iPhone, one NFC sheet per tag; see [On iPhone](iphone.md)):

- A new tag shows **New chunk found!** and its number, for example "Chunk 3 of 8".
- A tag you have already scanned shows **Duplicate chunk**; it is ignored. On iPhone the sheet closes with a red exclamation mark and the message "Chunk 3 of 8 already scanned".

**Archives in progress** lists every archive you have started to scan, with how many of its tags you have (for example 2/4). Your progress is saved: you can leave and come back later to scan the remaining tags. Tags from different archives can be mixed; each goes to its own archive.

To remove an unfinished archive from the list, tap its ✕. The bin icon at the top clears them all.

## 2. Restore

When the last tag is in, the app shows **All chunks received!**.

- **File name** (optional): leave it empty to use the original name.
- If the archive is encrypted ("This archive is encrypted"), enter the **Password**.

Tap **Restore Archive**. If you still want to scan something first, **Scan more tags** takes you back.

A finished archive in the **Archives in progress** list (with a checkmark) can also be tapped to get here.

## 3. Use the restored file

![Archive restored](../assets/screenshots/android-restore-complete.png){ width="300" }

**Archive Restored!** shows the file name. A short part of the archive ID is added to it, so files from different archives never overwrite each other. The file is stored inside the app, where other apps can't see it. To use it:

- **Open** opens it in an app that handles that type of file.
- **Save to device** opens the system's save dialog (Downloads by default), so you can keep a copy outside the app.
- **Share File** sends it to another app.

Restored files are also listed under **Archived Files** on the home screen. An archive of text shows the text directly, with a button to copy it.

## If something goes wrong

- **Wrong password**: the app says "Decryption failed: wrong password or corrupted data". Tap **Try Different Password** and enter it again.
- **Data Corruption Detected**: a tag's chunk failed its checksum (CRC). Tap **Rescan 1 Tag(s)** (the number varies) and scan the listed tags again; a good read replaces the damaged one.

More in [Troubleshooting](troubleshooting.md).
