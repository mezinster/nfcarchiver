# Chameleon reader

The [Chameleon Ultra](https://github.com/RfidResearchGroup/ChameleonUltra) is a small, pocket-sized NFC reader and emulator. NFC Archiver can use it over **Bluetooth** instead of the phone's own NFC, on iPhone and on Android.

## Why use one

- **Mifare Classic 1K on any phone.** Mifare Classic cards need the CRYPTO1 cipher. The Chameleon does it in its own chip, so it works whatever phone you have.
- **On iPhone it is the only way to use Mifare Classic.** The iPhone's own NFC can't read or write these cards at all.
- **Card inspection.** With a Chameleon connected, **Inspect card** shows what is on a card, block by block. The phone's own NFC has no raw access to cards, so this needs the Chameleon.

## Connecting

1. Switch the Chameleon on and keep it near the phone.
2. Turn Bluetooth on.
3. On the home screen, tap the **reader icon** in the top bar (an NFC symbol while the phone's own NFC is in use). The **Reader** screen opens.
4. Tap **Search**, then tap your Chameleon in the list.

The first time, the phone asks for Bluetooth permission. The app uses Bluetooth only to talk to your Chameleon; on Android it does not ask for your location.

Once connected, the reader icon shows a Bluetooth symbol, and **Create Archive** and **Restore Archive** use the Chameleon: put the tags on the Chameleon, not on the phone. On iPhone no NFC sheet appears in this mode. **Mifare Classic 1K** appears in the tag type list.

To go back to the phone's own NFC, open the **Reader** screen and tap **Disconnect**.

## If it isn't found

- "Bluetooth is off. Turn it on to use a Chameleon.": turn Bluetooth on.
- "Bluetooth permission is required to find a Chameleon.": allow the Bluetooth permission for NFC Archiver in the phone's settings.
- The list stays on "Searching for Chameleons…": wake the Chameleon and bring it closer. A weak Bluetooth signal also makes every operation slower.
- "Could not connect to the Chameleon.": switch the Chameleon off and on, then tap **Search** again.

More detail, including the card inspector, is in [CHAMELEON.md on GitHub](https://github.com/mezinster/nfcarchiver/blob/master/docs/CHAMELEON.md).
