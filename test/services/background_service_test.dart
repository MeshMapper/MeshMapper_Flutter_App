import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/background_service.dart';

void main() {
  group('BackgroundServiceManager.waitUntilStopped', () {
    test('returns at once when the service is already gone', () async {
      var calls = 0;
      final elapsed = await BackgroundServiceManager.waitUntilStopped(
        isRunning: () async {
          calls++;
          return false;
        },
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 200),
      );
      expect(elapsed, isNotNull);
      expect(calls, 1);
    });

    test('keeps polling until the service reports stopped', () async {
      var calls = 0;
      final elapsed = await BackgroundServiceManager.waitUntilStopped(
        isRunning: () async => ++calls < 3,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 2),
      );
      expect(elapsed, isNotNull);
      expect(calls, 3);
    });

    test('gives up at the bound and returns null', () async {
      final elapsed = await BackgroundServiceManager.waitUntilStopped(
        isRunning: () async => true,
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(milliseconds: 40),
      );
      expect(elapsed, isNull);
    });

    test('a throwing check counts as still running', () async {
      var calls = 0;
      final elapsed = await BackgroundServiceManager.waitUntilStopped(
        isRunning: () async {
          calls++;
          if (calls == 1) throw StateError('channel');
          return false;
        },
        pollInterval: const Duration(milliseconds: 5),
        timeout: const Duration(seconds: 1),
      );
      expect(elapsed, isNotNull);
      expect(calls, 2);
    });
  });
  group('BackgroundServiceManager start and stop', () {
    late _FakeService fake;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      fake = _FakeService();
      BackgroundServiceManager.debugInstallService(fake);
    });

    tearDown(() {
      BackgroundServiceManager.debugInstallService(null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('a disconnect during the wait for an old stop cancels the start', () {
      fakeAsync((async) {
        // A mode switch: the old mode is running, then stopped.
        BackgroundServiceManager.startService(title: 'A', body: 'a');
        async.flushMicrotasks();
        expect(fake.starts, 1);
        BackgroundServiceManager.stopService();
        fake.running = true; // The old service has not gone yet.

        // The new mode's start waits; a disconnect lands meanwhile, with
        // nothing marked running.
        BackgroundServiceManager.startService(title: 'B', body: 'b');
        async.elapse(const Duration(milliseconds: 250));
        BackgroundServiceManager.stopService();
        fake.running = false;
        async.elapse(const Duration(seconds: 5));

        expect(fake.starts, 1, reason: 'no orphan service after teardown');
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a service taken down by a late stop is started once more', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'A', body: 'a');
        async.flushMicrotasks();
        expect(fake.starts, 1);

        // The stale stopSelf() lands after the start.
        fake.running = false;
        fake.stayDown = true;
        async.elapse(const Duration(seconds: 1));
        expect(fake.starts, 2, reason: 'one retry');

        async.elapse(const Duration(seconds: 10));
        expect(fake.starts, 2, reason: 'never more than one retry');
      });
    });

    test('a stop before the post-start check prevents the retry', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'A', body: 'a');
        async.flushMicrotasks();
        BackgroundServiceManager.stopService();
        fake.running = false;
        async.elapse(const Duration(seconds: 5));
        expect(fake.starts, 1);
      });
    });

    test('a live stop ends a service this session did not start', () {
      fakeAsync((async) {
        // Started by BootReceiver: running, but not marked running here.
        fake.running = true;
        expect(BackgroundServiceManager.isRunning, isFalse);

        var done = false;
        BackgroundServiceManager.stopLiveService('orphaned service')
            .then((_) => done = true);
        async.flushMicrotasks();
        expect(fake.invoked, ['stop']);
        expect(done, isFalse, reason: 'waits for the service to go');

        fake.running = false;
        async.elapse(const Duration(milliseconds: 200));
        expect(done, isTrue);
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a live stop sends nothing when no service is running', () {
      fakeAsync((async) {
        var done = false;
        BackgroundServiceManager.stopLiveService('orphaned service')
            .then((_) => done = true);
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(fake.invoked, isEmpty);
      });
    });

    test('a live stop cancels a start waiting on an old stop', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'A', body: 'a');
        async.flushMicrotasks();
        expect(fake.starts, 1);
        BackgroundServiceManager.stopService();
        fake.running = true; // The old service has not gone yet.

        // The new mode's start waits; Close App lands meanwhile.
        BackgroundServiceManager.startService(title: 'B', body: 'b');
        async.elapse(const Duration(milliseconds: 250));
        BackgroundServiceManager.stopLiveService('exit app');
        fake.running = false;
        async.elapse(const Duration(seconds: 5));

        expect(fake.starts, 1, reason: 'no service after Close App');
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a live stop whose check fails sends nothing and does not throw', () {
      fakeAsync((async) {
        fake.running = true;
        fake.isRunningThrows = true;
        var threw = false;
        var done = false;
        BackgroundServiceManager.stopLiveService('orphaned service')
            .then((_) => done = true, onError: (Object _) => threw = true);
        async.flushMicrotasks();
        expect(threw, isFalse);
        expect(done, isTrue);
        expect(fake.invoked, isEmpty);
      });
    });

    test('a live stop leaves iOS alone', () {
      fakeAsync((async) {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        fake.running = true;
        BackgroundServiceManager.stopLiveService('exit app');
        async.flushMicrotasks();
        expect(fake.invoked, isEmpty);
      });
    });
  });
}

class _FakeService implements FlutterBackgroundService {
  bool running = false;
  bool stayDown = false;
  bool isRunningThrows = false;
  int starts = 0;
  final List<String> invoked = [];

  @override
  Future<bool> startService() async {
    starts++;
    running = !stayDown;
    return true;
  }

  @override
  Future<bool> isRunning() async {
    if (isRunningThrows) throw StateError('channel');
    return running;
  }

  @override
  void invoke(String method, [Map<String, dynamic>? arg]) {
    invoked.add(method);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
