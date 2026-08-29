import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/serial_task_gate.dart';

/// #495: concurrent MapLibre style mutations (zone-transfer overlay rebuild
/// racing the post-upload patch refresh) double-added the coverage patch
/// source. The gate serializes those mutation flows; these tests pin down the
/// semantics the map code relies on.
void main() {
  test('tasks run strictly in submission order, never overlapping', () {
    fakeAsync((async) {
      final gate = SerialTaskGate();
      final events = <String>[];
      var running = 0;
      var maxConcurrent = 0;

      Future<void> task(String name, Duration length) async {
        running++;
        if (running > maxConcurrent) maxConcurrent = running;
        events.add('$name start');
        await Future<void>.delayed(length);
        events.add('$name end');
        running--;
      }

      gate.run(() => task('a', const Duration(milliseconds: 30)));
      gate.run(() => task('b', const Duration(milliseconds: 10)));
      gate.run(() => task('c', const Duration(milliseconds: 20)));
      async.elapse(const Duration(milliseconds: 100));

      expect(maxConcurrent, 1,
          reason: 'a queued task must never start before the previous ended');
      expect(events, [
        'a start',
        'a end',
        'b start',
        'b end',
        'c start',
        'c end',
      ]);
    });
  });

  test('a task result is returned to its caller', () {
    fakeAsync((async) {
      final gate = SerialTaskGate();
      int? result;
      gate.run(() async => 42).then((v) => result = v);
      async.flushMicrotasks();
      expect(result, 42);
    });
  });

  test('a throwing task fails its own caller but not the queue', () {
    fakeAsync((async) {
      final gate = SerialTaskGate();
      Object? error;
      var laterRan = false;

      gate.run<void>(() async {
        throw StateError('boom');
      }).then((_) {}, onError: (Object e) {
        error = e;
      });
      gate.run(() async {
        laterRan = true;
      });
      async.flushMicrotasks();

      expect(error, isA<StateError>(),
          reason: 'the error must reach the task submitter');
      expect(laterRan, isTrue,
          reason: 'one failed task must not poison the tasks behind it');
    });
  });

  test('a task queued from within a running task does not deadlock', () {
    fakeAsync((async) {
      final gate = SerialTaskGate();
      final events = <String>[];

      gate.run(() async {
        events.add('outer start');
        // NOT awaited: awaiting a nested enqueue from inside the gate would
        // deadlock by design (it runs only after the current task finishes).
        gate.run(() async => events.add('inner'));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        events.add('outer end');
      });
      async.elapse(const Duration(milliseconds: 50));

      expect(events, ['outer start', 'outer end', 'inner']);
    });
  });
}
