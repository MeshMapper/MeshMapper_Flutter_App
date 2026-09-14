import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/async_callback_boundary.dart';
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

  test('can be reused after an error has drained', () async {
    final runner = CoalescedAsyncRunner();

    await expectLater(
      runner.run(() async => throw StateError('first run failed')),
      throwsA(isA<StateError>()),
    );

    var secondRunCompleted = false;
    await runner.run(() async {
      secondRunCompleted = true;
    });

    expect(secondRunCompleted, isTrue);
  });

  test('cancellation prevents a pending operation from starting', () async {
    final runner = CoalescedAsyncRunner();
    final release = Completer<void>();
    final started = Completer<void>();
    final events = <String>[];

    final active = runner.run(() async {
      events.add('active start');
      started.complete();
      await release.future;
      if (!runner.isCancelled) events.add('active side effect');
    });
    await started.future;

    final pending = runner.run(() async {
      events.add('pending start');
    });
    runner.cancel();
    release.complete();

    await active;
    await pending;

    expect(events, ['active start']);
    expect(runner.isCancelled, isFalse);
  });

  test('cancellation suppresses an error from the active operation', () async {
    final runner = CoalescedAsyncRunner();
    final release = Completer<void>();
    final started = Completer<void>();

    final active = runner.run(() async {
      started.complete();
      await release.future;
      throw StateError('disposed controller');
    });
    await started.future;

    runner.cancel();
    release.complete();

    await active;
    expect(runner.isCancelled, isFalse);
  });

  test('void async callback boundary reports failures without rethrowing',
      () async {
    final reported = <Object>[];

    runAsyncCallbackSafely(
      () async => throw StateError('callback failed'),
      onError: (error, _) => reported.add(error),
    );
    await Future<void>.delayed(Duration.zero);

    expect(reported, hasLength(1));
    expect(reported.single, isA<StateError>());
  });
}
