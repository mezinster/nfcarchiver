import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/core/chameleon/chameleon_device.dart';
import 'package:nfc_archiver/core/constants/nfar_format.dart';
import 'package:nfc_archiver/core/mifare/card_layout.dart';
import 'package:nfc_archiver/core/models/chunk.dart';
import 'package:nfc_archiver/features/nfc/data/chameleon_reader.dart';
import 'package:nfc_archiver/features/nfc/domain/card_reader.dart';

import 'support/fake_chameleon_device.dart';
import 'support/helpers.dart';

/// Put a real NFAR chunk on the fake Classic card, laid out the way the app
/// writes it.
void _writeChunkToCard(FakeChameleonDevice dev, Uint8List bytes) {
  for (final w in chunkToBlocks(bytes)) {
    dev.setBlock(w.block, w.data);
  }
}

ChameleonReader _reader(FakeChameleonDevice dev) =>
    ChameleonReader(dev, pollInterval: Duration.zero);

void main() {
  test('ChameleonReader is a CardReader that supports raw access', () {
    final r = _reader(FakeChameleonDevice.classic1k());
    expect(r, isA<CardReader>());
    expect(r.name, 'chameleon-ble');
    expect(r.supportsRawAccess, isTrue,
        reason: 'this is what gates the card inspector');
  });

  test('a read session delivers the chunk on the card', () async {
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    Chunk? got;
    final stop = await _reader(dev).startReadSession(
      onChunkRead: (c, _) => got = c,
      onError: (_) {},
    );
    await pumpUntil(() => got != null);
    stop();

    expect(got!.payload.length, 32);
    expect(got!.chunkIndex, 0);
  });

  test('the stop closure ends polling', () async {
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    final reader = _reader(dev);
    var reads = 0;
    final stop = await reader.startReadSession(
      onChunkRead: (_, __) => reads++,
      onError: (_) {},
    );
    await pumpUntil(() => reads > 0);
    stop();
    expect(reader.isSessionActive, isFalse);

    final seen = reads;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(reads, seen, reason: 'no further reads after stop');
  });

  test('the same card is not re-read while it rests on the reader', () async {
    // Without this, a card left in the field floods the restore loop with
    // duplicates of one chunk.
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    var reads = 0;
    final stop = await _reader(dev)
        .startReadSession(onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads > 0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    stop();
    expect(reads, 1);
  });

  test('lifting and re-presenting a card reads it again', () async {
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    var reads = 0;
    final stop = await _reader(dev)
        .startReadSession(onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads == 1);
    dev.removeCard();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    dev.presentCard();
    await pumpUntil(() => reads == 2);
    stop();
    expect(reads, 2);
  });

  test('a foreign card reports an error but does NOT end the session', () async {
    // Auth failure means a hotel key on the reader, not a broken session.
    // Ending here would abort a restore because one wrong card was tapped.
    //
    // Sector 0 specifically: a genuine foreign card is keyed throughout, and
    // locking only a later sector would never surface — the first usable block
    // lives in sector 0, and a non-NFAR card is abandoned there as blank.
    final dev = FakeChameleonDevice.classic1k(
      sectorKeys: {
        for (var s = 0; s < 16; s++) s: Uint8List.fromList(const [9, 9, 9, 9, 9, 9]),
      },
    );
    await dev.connect();

    final reader = _reader(dev);
    var errors = 0;
    final stop = await reader.startReadSession(
      onChunkRead: (_, __) {},
      onError: (_) => errors++,
    );
    await pumpUntil(() => errors > 0);
    expect(reader.isSessionActive, isTrue);
    stop();
  });

  test('a blank card is skipped quietly, not reported as an error', () async {
    // A card with no chunk is a normal thing to tap during a restore.
    final dev = FakeChameleonDevice.classic1k();
    await dev.connect();

    var errors = 0;
    var reads = 0;
    final stop = await _reader(dev).startReadSession(
      onChunkRead: (_, __) => reads++,
      onError: (_) => errors++,
    );
    await Future<void>.delayed(const Duration(milliseconds: 30));
    stop();
    expect(reads, 0);
    expect(errors, 0);
  });

  group('writing', () {
    test('a chunk is written and verified by reading it back', () async {
      final dev = FakeChameleonDevice.classic1k();
      await dev.connect();

      NfcTagInfoLike? ok;
      final stop = await _reader(dev).startWriteSession(
        chunk: aChunk(),
        configuredTagType: NfcTagType.mifareClassic1k,
        onSuccess: (info) => ok = info,
        onError: (_) {},
      );
      await pumpUntil(() => ok != null);
      stop();

      expect(await dev.readBlock(usableBlockIndexes.first, factoryKeyA),
          equals(chunkToBlocks(aChunk().toBytes()).first.data));
    });

    test('a write whose read-back differs is reported, not silently accepted',
        () async {
      final dev = FakeChameleonDevice.classic1k()..corruptWrites();
      await dev.connect();

      String? err;
      final stop = await _reader(dev).startWriteSession(
        chunk: aChunk(),
        configuredTagType: NfcTagType.mifareClassic1k,
        onSuccess: (_) {},
        onError: (m) => err = m,
      );
      await pumpUntil(() => err != null);
      stop();
      expect(err, isNotNull);
    });

    test('a chunk too large for the card is rejected before any write',
        () async {
      final dev = FakeChameleonDevice.classic1k();
      await dev.connect();
      final before = await dev.readBlock(usableBlockIndexes.first, factoryKeyA);

      String? err;
      final stop = await _reader(dev).startWriteSession(
        chunk: aChunk(payloadLength: cardCapacityBytes + 100),
        configuredTagType: NfcTagType.mifareClassic1k,
        onSuccess: (_) {},
        onError: (m) => err = m,
      );
      await pumpUntil(() => err != null);
      stop();

      expect(await dev.readBlock(usableBlockIndexes.first, factoryKeyA),
          equals(before),
          reason: 'nothing may be written when the chunk cannot fit');
    });
  });

  test('a resting card is not re-read when the session RESTARTS', () async {
    // Observed on hardware: the restore screen restarts the session after
    // every successful read (a phone-NFC habit, where one tap is one session).
    // Clearing the resting-card guard on start made the same card look new
    // each time, so it was re-read about once a second forever.
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    final reader = _reader(dev);
    var reads = 0;
    await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads == 1);

    // Restart exactly as the screen does after a success.
    final stop = await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await Future<void>.delayed(const Duration(milliseconds: 30));
    stop();

    expect(reads, 1, reason: 'the card never left the field');
  });

  test('connecting clears the guard, so a card already resting is picked up',
      () async {
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    final reader = _reader(dev);

    var reads = 0;
    await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads == 1);

    // Reconnecting is a fresh start: whatever is on the reader is new again.
    await reader.connect();
    final stop = await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads == 2);
    stop();
    expect(reads, 2);
  });

  test('starting a session twice supersedes — it does not stack loops', () async {
    // The first hardware scan hung on exactly this: scan_screen restarts the
    // session on every error, each start spawned another poll loop, and they
    // all raced for a device that permits one command in flight. Only the
    // newest generation may keep polling.
    final dev = FakeChameleonDevice.classic1k();
    _writeChunkToCard(dev, validChunkBytes());
    await dev.connect();

    final reader = _reader(dev);
    var reads = 0;
    await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    final stop2 = await reader.startReadSession(
        onChunkRead: (_, __) => reads++, onError: (_) {});
    await pumpUntil(() => reads > 0);
    stop2();
    await Future<void>.delayed(const Duration(milliseconds: 30));

    expect(reader.isSessionActive, isFalse,
        reason: 'stopping the NEWEST session must stop all polling');
    final settled = reads;
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(reads, settled, reason: 'no orphaned loop is still running');
  });

  test('a stale stop closure cannot cancel the session that replaced it',
      () async {
    final dev = FakeChameleonDevice.classic1k();
    await dev.connect();
    final reader = _reader(dev);

    final stale = await reader.startReadSession(
        onChunkRead: (_, __) {}, onError: (_) {});
    await reader.startReadSession(onChunkRead: (_, __) {}, onError: (_) {});
    stale();

    expect(reader.isSessionActive, isTrue,
        reason: 'the newer session owns the loop');
  });

  test('connect and disconnect drive the underlying device', () async {
    final dev = FakeChameleonDevice.classic1k();
    final reader = ChameleonReader(dev, pollInterval: Duration.zero);
    await reader.connect();
    expect(dev.isConnected, isTrue);
    await reader.disconnect();
    expect(dev.disconnectCalls, 1);
  });
}

/// Local alias so the test does not depend on the app's NfcTagInfo import path.
typedef NfcTagInfoLike = Object;
