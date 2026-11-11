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
    required this.semanticLabel,
    required this.step,
    required this.onStep,
    this.onHoldStart,
    this.onHoldEnd,
  });

  final IconData icon;

  /// What a screen reader announces for the button, e.g. "More tags".
  final String semanticLabel;

  /// The delta of one step: 1 or -1.
  final int step;
  final void Function(int delta) onStep;

  /// Called before the first repeated step of a hold.
  final VoidCallback? onHoldStart;

  /// Called once when a hold that repeated ends: released, cancelled, or cut
  /// short by the button leaving the tree. Always called from a microtask,
  /// never synchronously from the gesture or from dispose.
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

  /// Between [RepeatButton.onHoldStart] and [RepeatButton.onHoldEnd].
  bool _holding = false;

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
      _holding = true;
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
    _endHold();
  }

  /// Ends a started hold exactly once, however it ends: release, cancel, or
  /// the button leaving the tree. Deferred to a microtask because the last
  /// two can arrive during tree teardown (the tap recogniser cancels from its
  /// own dispose), where the listener must not be touched.
  void _endHold() {
    if (!_holding) return;
    _holding = false;
    final onHoldEnd = widget.onHoldEnd;
    if (onHoldEnd != null) scheduleMicrotask(onHoldEnd);
  }

  void _tap() {
    // A released hold has already stepped; only a plain tap steps here.
    if (!_repeated) widget.onStep(widget.step);
    _repeated = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _endHold();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // No Tooltip: its long-press recogniser would compete with the hold. The
    // Semantics restores the button role and name a bare InkResponse lacks.
    return Semantics(
      button: true,
      label: widget.semanticLabel,
      excludeSemantics: true,
      onTap: () => widget.onStep(widget.step),
      child: InkResponse(
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
      ),
    );
  }
}
