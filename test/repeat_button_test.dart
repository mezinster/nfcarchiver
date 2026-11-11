import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nfc_archiver/shared/widgets/repeat_button.dart';

void main() {
  late int total;
  late int steps;
  late int holdStarts;
  late int holdEnds;

  setUp(() {
    total = 0;
    steps = 0;
    holdStarts = 0;
    holdEnds = 0;
  });

  Widget button() => MaterialApp(
        home: Scaffold(
          body: Center(
            child: RepeatButton(
              icon: Icons.add,
              step: 1,
              onStep: (d) {
                total += d;
                steps++;
              },
              onHoldStart: () => holdStarts++,
              onHoldEnd: () => holdEnds++,
            ),
          ),
        ),
      );

  testWidgets('one tap is one step', (tester) async {
    await tester.pumpWidget(button());
    await tester.tap(find.byIcon(Icons.add));
    await tester.pump(const Duration(seconds: 2));
    expect(total, 1);
    expect(holdStarts, 0);
    expect(holdEnds, 0);
  });

  testWidgets('holding follows the schedule, then stops on release',
      (tester) async {
    await tester.pumpWidget(button());
    final g =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.add)));

    // Steps at 400 ms, then every 300 ms.
    await tester.pump(const Duration(milliseconds: 500));
    expect(total, 1);
    expect(holdStarts, 1);
    // 400, 700, 1000, then every 100 ms: 1100..1500.
    await tester.pump(const Duration(milliseconds: 1000));
    expect(total, 8);
    // 13 by 2000, then every 50 ms: 2050..2500.
    await tester.pump(const Duration(milliseconds: 1000));
    expect(total, 23);
    // 32 by 2950, then 3000..3500 step 10 at a time (11 steps).
    await tester.pump(const Duration(milliseconds: 1000));
    expect(total, 142);

    await g.up();
    await tester.pump();
    final atRelease = total;
    expect(holdEnds, 1);
    await tester.pump(const Duration(seconds: 2));
    expect(total, atRelease, reason: 'no step after release');
    expect(steps, 43, reason: 'the release adds no tap step');
  });

  testWidgets('a hold released before the first repeat is a tap',
      (tester) async {
    await tester.pumpWidget(button());
    final g =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.add)));
    await tester.pump(const Duration(milliseconds: 300));
    await g.up();
    await tester.pump(const Duration(seconds: 1));
    expect(total, 1);
    expect(holdEnds, 0);
  });

  testWidgets('disposing mid-hold stops the repeat', (tester) async {
    await tester.pumpWidget(button());
    final g =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.add)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(total, 1);

    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 3));
    expect(total, 1);
    expect(holdEnds, 1, reason: 'a hold cut short by dispose still ends');
    expect(tester.takeException(), isNull);
    await g.up();
    await tester.pump();
    expect(holdEnds, 1);
  });

  testWidgets('disposing before the first repeat ends no hold', (tester) async {
    await tester.pumpWidget(button());
    final g =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.add)));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const MaterialApp(home: SizedBox()));
    await tester.pump(const Duration(seconds: 1));
    expect(total, 0);
    expect(holdStarts, 0);
    expect(holdEnds, 0);
    await g.up();
  });

  testWidgets('a negative step repeats downwards', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: RepeatButton(
            icon: Icons.remove, step: -1, onStep: (d) => total += d),
      ),
    ));
    final g =
        await tester.startGesture(tester.getCenter(find.byIcon(Icons.remove)));
    await tester.pump(const Duration(milliseconds: 1000));
    await g.up();
    expect(total, -3);
  });
}
