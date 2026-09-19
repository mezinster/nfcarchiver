import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/nfc/domain/stale_tag_policy.dart';

/// Android keeps a card that stays in the field "connected" and answers a new
/// enableReaderMode with `Not updating discovery parameters, tag connected`:
/// the new session never hears about the card. Dropping the connection first
/// fixes that — but the same carry-over is also what stops two loops, so it
/// must not be dropped everywhere. Each case below was seen on a Pixel 8 Pro.
void main() {
  late StaleTagPolicy policy;
  setUp(() => policy = StaleTagPolicy());

  test('the first session releases: a card already on the phone must be seen',
      () {
    // The stuck write: card resting on the phone, Start pressed, spinner for
    // four minutes until the card was lifted.
    expect(policy.shouldReleaseBefore(SessionKind.write), isTrue);
    expect(policy.shouldReleaseBefore(SessionKind.read), isTrue);
  });

  test('re-arming after a successful read does not release', () {
    // The scan screen re-arms itself after every read. Releasing there
    // re-read the same card every 0.75 s, vibrating each time.
    policy.succeeded(SessionKind.read);
    expect(policy.shouldReleaseBefore(SessionKind.read), isFalse);
  });

  test('arming the next chunk after a successful write does not release', () {
    // Otherwise chunk 2 is written over the card that just received chunk 1
    // if the user has not lifted it yet. UIDs cannot guard this: cloned cards
    // share one.
    policy.succeeded(SessionKind.write);
    expect(policy.shouldReleaseBefore(SessionKind.write), isFalse);
  });

  test('a write armed after a read releases', () {
    // Inspect or scan a card, leave it on the phone, then archive to it.
    policy.succeeded(SessionKind.read);
    expect(policy.shouldReleaseBefore(SessionKind.write), isTrue);
  });

  test('a read armed after a write releases', () {
    // Verify a card straight after writing it, without lifting it.
    policy.succeeded(SessionKind.write);
    expect(policy.shouldReleaseBefore(SessionKind.read), isTrue);
  });

  test('the protection is spent by one arm', () {
    // A retry after an error re-arms with the same card still in place, and
    // has to see it.
    policy.succeeded(SessionKind.write);
    policy.shouldReleaseBefore(SessionKind.write);
    expect(policy.shouldReleaseBefore(SessionKind.write), isTrue);
  });
}
