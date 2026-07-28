# Hardware Testing — Chameleon Ultra + Mifare Classic 1K

Automated tests cover everything up to a FakeChameleon. These steps validate the
real device and must be run manually on a Chromium browser (Chrome/Edge) on a
machine with Bluetooth. **WSL2 has no Bluetooth** — run the browser on the
Windows host and point it at the WSL dev server URL.

## Setup
1. `cd webapp && source ~/.nvm/nvm.sh && nvm use --lts && npm run app`
2. Open `http://localhost:8000` (or the WSL host IP:8000 from Windows) in Chrome/Edge.
3. Have a Chameleon Ultra (charged, firmware supporting BLE) and 2 blank
   Mifare Classic 1K cards with factory key A (`FF FF FF FF FF FF`).

## Checklist
- [ ] **BLE pairing (the deferred spike):** Click "Connect Chameleon", pick the
      device, confirm it pairs (PIN default `123456`). Status shows "connected".
      If pairing fails, run `hw settings bleclearbonds` on the device and retry.
- [ ] **Single-block read:** With a card on the reader, the app can scan its UID
      (Restore → "Tap the first card" shows a collected count or a
      no-NFAR-data message on a blank card).
- [ ] **Archive a small file across 2 cards:** Pick a ~1 KB file, compress on,
      Archive; tap card 1 then card 2 when prompted. Confirm "Done".
- [ ] **Overwrite guard:** Archive again to one of the written cards; confirm the
      overwrite prompt appears.
- [ ] **Restore round-trip:** Restore, tap both cards in either order, confirm
      the downloaded file is byte-identical to the original (`sha256sum`).
- [ ] **Encrypted round-trip:** Repeat archive with a password; confirm restore
      prompts for it and rejects a wrong one.
- [ ] **Write-verify:** Pull a card away mid-write; confirm a
      verification/timeout error rather than silent corruption.
