import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/coalesced_async_runner.dart';

void main() {
  test('coalesces callbacks during a run into one non-overlapping follow-up',
      () async {
    final runner = CoalescedAsyncRunner();
    final firstRelease = Completer<void>();
    final firstStarted = Completer<void>();
    final events = <String>[];
    var running = 0;
    var maxConcurrent = 0;

    Future<void> operation(String name, {Completer<void>? waitFor}) async {
      running++;
      if (running > maxConcurrent) maxConcurrent = running;
      events.add('$name start');
      if (waitFor != null) await waitFor.future;
      events.add('$name end');
      running--;
    }

    final first = runner.run(() async {
      firstStarted.complete();
      await operation('first', waitFor: firstRelease);
    });
    await firstStarted.future;

    runner.run(() => operation('second'));
    final followUp = runner.run(() => operation('latest'));
    firstRelease.complete();

    await first;
    await followUp;

    expect(maxConcurrent, 1);
    expect(events, [
      'first start',
      'first end',
      'latest start',
      'latest end',
    ]);
  });

  test('runs a pending follow-up even when the active run throws', () async {
    final runner = CoalescedAsyncRunner();
    final release = Completer<void>();
    final started = Completer<void>();
    var followUpRuns = 0;

    final active = runner.run(() async {
      started.complete();
      await release.future;
      throw StateError('style restoration failed');
    });
    await started.future;

    final pending = runner.run(() async {
      followUpRuns++;
    });
    release.complete();

    await expectLater(active, throwsA(isA<StateError>()));
    await expectLater(pending, throwsA(isA<StateError>()));
    expect(followUpRuns, 1);
  });
}
