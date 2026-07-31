import '../../../core/chameleon/cancellation_token.dart';
import '../../../core/chameleon/chameleon_device.dart';
import '../../../core/inspect/card_dump.dart';
import '../../../core/inspect/diagnose_card.dart';
import '../../../core/inspect/hex_view.dart';
import '../../../core/inspect/nfar_describe.dart';
import '../../../core/inspect/nfar_source.dart';
import '../../../core/log/logger.dart';
import '../../../core/mifare/card_layout.dart';
import 'inspect_sink.dart';

/// Dump the presented card and report it through [sink].
///
/// Port of `runInspection` in `webapp/app/ui/inspect-orchestrator.ts`.
/// Read-only throughout: nothing here writes to a card.
Future<void> runInspection(
  ChameleonDevice dev,
  InspectSink sink, {
  CancellationToken? token,
}) async {
  sink.setStatus('Hold the card still on the reader…');

  // Advisory only. readBlock performs its own select, so a card that refuses
  // anticollision can still be dumped in full — a failure here must not stop
  // anything.
  CardDiagnosis? diag;
  try {
    diag = await diagnoseCard(dev);
  } catch (e) {
    log.debug('inspect', 'Anticollision failed — continuing', {'error': '$e'});
    diag = null;
  }

  NfarDescription nfar = const NfarAbsent('no data read yet');
  final seen = <DumpUnit>[];

  try {
    final result = await dumpCard(
      dev,
      DumpCallbacks(
        // Before the first read, so identity is on screen in about a second
        // rather than after ~64 BLE round trips.
        onMeta: (meta) => sink.setIdentity(formatIdentity(meta, _toDiag(diag))),
        onUnit: (unit, done, total) {
          seen.add(unit);
          sink.appendRow(formatUnitRow(unit));
          sink.setProgress(
            done == total ? 'Read $done of $total' : 'Reading $done of $total…',
          );

          // Re-describe only while the chunk is still incomplete; once the
          // declared tail is covered the description stops changing.
          if (nfar is NfarAbsent || (nfar as NfarPresent).crcValid == null) {
            final isClassic = unit.sector != null;
            final src = nfarBytesSoFar(seen, isClassic: isClassic);
            nfar = switch (src) {
              // Mifare Classic has a fixed known capacity, so a declared
              // length past it is worth flagging. On NTAG the chunk arrives
              // inside an NDEF envelope whose own TLV length already bounds
              // it, so no capacity is guessed.
              SourceBytes(:final bytes) => describeNfar(
                  bytes,
                  capacityBytes: isClassic ? cardCapacityBytes : null,
                ),
              SourceNoEnvelope(:final reason) => NfarAbsent(reason),
              SourceForeign(:final reason) => NfarAbsent(reason),
              SourceUnreadable(:final reason) => NfarAbsent(reason),
            };
            sink.setNfar(formatNfar(nfar));
          }
        },
      ),
      token: token,
    );

    sink.setNfar(formatNfar(nfar));
    sink.setReport(
      formatReport(result.meta, _toDiag(diag), nfar, result.units),
    );
    sink.setStatus(
      result.aborted
          ? 'Stopped.'
          : result.cardLost
              ? 'Card left the field — partial dump.'
              : 'Inspection complete.',
    );
    log.info('inspect', 'Inspection finished', {
      'units': result.units.length,
      'aborted': result.aborted,
      'cardLost': result.cardLost,
    });
  } on UnsupportedTagException catch (e) {
    // Kept verbatim: this message names the SAK, and for an inspector that
    // value IS the result. A generic string would discard the finding.
    sink.setStatus(e.message);
    log.warn('inspect', 'Unsupported tag', {'why': e.message});
  } catch (e) {
    sink.setStatus('$e');
    log.error('inspect', 'Inspection failed', {'error': '$e'});
  }
}

/// [CardDiagnosis] satisfies [IdentityDiagnosis] field for field; the formatter
/// declares its own type so it stays independent of how identity was obtained.
IdentityDiagnosis? _toDiag(CardDiagnosis? d) => d == null
    ? null
    : IdentityDiagnosis(
        atqa: d.atqa,
        uidCl1: d.uidCl1,
        bccReturned: d.bccReturned,
        bccComputed: d.bccComputed,
        bccValid: d.bccValid,
        isCascade: d.isCascade,
      );
