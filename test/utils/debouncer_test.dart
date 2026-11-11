import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/debouncer.dart';

void main() {
  const delay = Duration(milliseconds: 1500);

  test('a burst of changes ends in one call with the newest action', () {
    fakeAsync((async) {
      final d = Debouncer(delay);
      final calls = <int>[];
      for (var i = 0; i < 10; i++) {
        d.schedule(() => calls.add(i));
        async.elapse(const Duration(milliseconds: 100));
      }
      expect(calls, isEmpty);
      async.elapse(delay);
      expect(calls, [9]);
      expect(d.isPending, isFalse);
    });
  });

  test('each schedule restarts the wait', () {
    fakeAsync((async) {
      final d = Debouncer(delay);
      var calls = 0;
      d.schedule(() => calls++);
      async.elapse(const Duration(milliseconds: 1400));
      d.schedule(() => calls++);
      async.elapse(const Duration(milliseconds: 1400));
      expect(calls, 0);
      async.elapse(const Duration(milliseconds: 100));
      expect(calls, 1);
    });
  });

  test('flush runs a pending action now, once', () {
    fakeAsync((async) {
      final d = Debouncer(delay);
      var calls = 0;
      d.schedule(() => calls++);
      d.flush();
      expect(calls, 1);
      async.elapse(delay * 2);
      expect(calls, 1);
      d.flush();
      expect(calls, 1);
    });
  });

  test('cancel drops the pending action', () {
    fakeAsync((async) {
      final d = Debouncer(delay);
      var calls = 0;
      d.schedule(() => calls++);
      d.cancel();
      async.elapse(delay * 2);
      expect(calls, 0);
    });
  });
}
