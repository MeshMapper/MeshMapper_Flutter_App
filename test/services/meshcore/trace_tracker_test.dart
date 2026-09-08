import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/trace_tracker.dart';

/// Trace reuses the shared discovery-window countdown but, unlike discovery,
/// needs no teardown stop of its own: [TraceTracker.dispose] calls
/// `_endWindow()` while listening, which fires `onWindowComplete` (the hook the
/// provider stops the countdown from) and cancels the window timer. This pins
/// that behaviour directly on the tracker, so it holds regardless of what
/// `forceDisableAutoPing` happens to stop on its own (a PingService-level test
/// cannot tell the two apart, because the shared countdown is stopped either
/// way).

Uint8List _tag() => Uint8List.fromList([1, 2, 3, 4]);

void main() {
  test('dispose while listening ends the window and fires completion', () {
    final tracker = TraceTracker();
    final completions = <TraceResult?>[];
    tracker.onWindowComplete = completions.add;

    tracker.startTracking(tag: _tag(), targetRepeaterId: '4E');
    expect(tracker.isListening, isTrue);

    tracker.dispose();

    expect(tracker.isListening, isFalse,
        reason: 'dispose must end the listening window');
    expect(completions, hasLength(1),
        reason: 'dispose while listening fires onWindowComplete, the stop hook');
    expect(completions.single, isNull,
        reason: 'no trace response arrived, so the result is null');
  });

  test('dispose cancels the window timer so it cannot fire again', () {
    fakeAsync((async) {
      final tracker = TraceTracker();
      final completions = <TraceResult?>[];
      tracker.onWindowComplete = completions.add;

      tracker.startTracking(
        tag: _tag(),
        targetRepeaterId: '4E',
        windowDuration: const Duration(seconds: 7),
      );
      tracker.dispose();
      expect(completions, hasLength(1));

      // Well past the window: a leaked timer would fire _endWindow a second
      // time. dispose nulls the timer, so the count stays at one.
      async.elapse(const Duration(seconds: 10));
      expect(completions, hasLength(1),
          reason: 'the window timer was cancelled by dispose');
    });
  });

  test('dispose when idle is a no-op that fires no completion', () {
    final tracker = TraceTracker();
    final completions = <TraceResult?>[];
    tracker.onWindowComplete = completions.add;

    // Never started, so there is no window to end.
    tracker.dispose();

    expect(tracker.isListening, isFalse);
    expect(completions, isEmpty,
        reason: 'no window was open, so onWindowComplete must not fire');
  });
}
