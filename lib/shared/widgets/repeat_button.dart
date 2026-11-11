import 'dart:async';

import 'package:flutter/material.dart';

/// An icon button that steps once per tap and repeats while held.
///
/// Holding waits [initialDelay], then steps every 300 ms; after 1 s of holding
/// every 100 ms, after 2 s every 50 ms, and from 3 s on each step is 10 times
/// [step]. Elapsed time is the sum of the scheduled delays, so the schedule is
/// exact under fake async.
class RepeatButton extends StatefulWidget {
  const RepeatButton({
    super.key,
    required this.icon,
    required this.step,
    required this.onStep,
    this.onHoldStart,
    this.onHoldEnd,
  });

  final IconData icon;

  /// The delta of one step: 1 or -1.
  final int step;
  final void Function(int delta) onStep;

  /// Called before the first repeated step of a hold.
  final VoidCallback? onHoldStart;

  /// Called when a hold that repeated is released or cancelled (not when the
  /// button is disposed mid-hold).
  final VoidCallback? onHoldEnd;

  static const initialDelay = Duration(milliseconds: 400);

  /// The delay before the next repeat, after [elapsed] of holding.
  static Duration intervalAfter(Duration elapsed) {
    final ms = elapsed.inMilliseconds;
    if (ms < 1000) return const Duration(milliseconds: 300);
    if (ms < 2000) return const Duration(milliseconds: 100);
    return const Duration(milliseconds: 50);
  }

  /// The step multiplier after [elapsed] of holding.
  static int multiplierAfter(Duration elapsed) =>
      elapsed.inMilliseconds >= 3000 ? 10 : 1;

  @override
  State<RepeatButton> createState() => _RepeatButtonState();
}

class _RepeatButtonState extends State<RepeatButton> {
  Timer? _timer;
  Duration _elapsed = Duration.zero;
  bool _repeated = false;

  void _down() {
    _timer?.cancel();
    _repeated = false;
    _elapsed = RepeatButton.initialDelay;
    _timer = Timer(RepeatButton.initialDelay, _repeat);
  }

  void _repeat() {
    if (!mounted) return;
    if (!_repeated) {
      _repeated = true;
      widget.onHoldStart?.call();
    }
    widget.onStep(widget.step * RepeatButton.multiplierAfter(_elapsed));
    final next = RepeatButton.intervalAfter(_elapsed);
    _elapsed += next;
    _timer = Timer(next, _repeat);
  }

  void _release() {
    _timer?.cancel();
    _timer = null;
    if (_repeated) widget.onHoldEnd?.call();
  }

  void _tap() {
    // A released hold has already stepped; only a plain tap steps here.
    if (!_repeated) widget.onStep(widget.step);
    _repeated = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // No Tooltip: its long-press recogniser would compete with the hold.
    return InkResponse(
      onTapDown: (_) => _down(),
      onTapUp: (_) => _release(),
      onTapCancel: () {
        _release();
        _repeated = false;
      },
      onTap: _tap,
      radius: 24,
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(child: Icon(widget.icon)),
      ),
    );
  }
}
