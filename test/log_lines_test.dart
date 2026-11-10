import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/features/diagnostics/log_lines.dart';

void main() {
  const text = '=== NFC Archiver 1 (2) · ios · en · session start ===\n'
      '10:00:00.000 INFO  [nfc] hello x=1\n'
      '10:00:01.000 ERROR [nfc] boom\n'
      '    PlatformException(x)\n'
      '    #0 frame\n'
      '10:00:02.000 WARN  [nfc] hmm\n';

  test('classifies headers, entries and detail lines', () {
    final l = parseLogLines(text);
    expect(l.length, 6);
    expect(l[0].isHeader, isTrue);
    expect(l[1].level, LogLineLevel.info);
    expect(l[2].level, LogLineLevel.error);
    expect(l[3].isDetail, isTrue);
    expect(l[3].level, LogLineLevel.error);
    expect(l[5].level, LogLineLevel.warn);
  });

  test('onlyProblems keeps detail and headers, drops info', () {
    final l = onlyProblems(parseLogLines(text));
    expect(l.map((e) => e.text).any((t) => t.contains('hello')), isFalse);
    expect(l.length, 5);
  });
}
