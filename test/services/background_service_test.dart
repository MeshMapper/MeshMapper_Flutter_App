import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/background_service.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('meshmapper/session_service');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  /// Captures every debug line written from here to the end of the test.
  List<String> captureLogs() {
    final logs = <String>[];
    final originalPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logs.add(message);
    };
    DebugLogger.setEnabled(true);
    addTearDown(() {
      debugPrint = originalPrint;
      DebugLogger.setEnabled(false);
    });
    return logs;
  }

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

  group('BackgroundServiceManager on the Android session service', () {
    late List<MethodCall> calls;
    late FutureOr<Object?> Function() startReply;
    late Map<String, Object?> status;

    List<String> methods() => calls.map((c) => c.method).toList();
    int count(String method) => methods().where((m) => m == method).length;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      BackgroundServiceManager.debugInstallService(null);
      calls = [];
      startReply = () => {'started': true, 'error': null};
      status = {'running': true, 'lastError': null};
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'start':
            return startReply();
          case 'status':
            return status;
          default:
            return null;
        }
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      BackgroundServiceManager.debugInstallService(null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('the service follows the connection on Android only', () {
      expect(BackgroundServiceManager.followsConnection, isTrue);
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(BackgroundServiceManager.followsConnection, isFalse);
    });

    test('a start the caller no longer wants sends nothing', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(
            title: 'T', body: 'B', mayStart: () => false);
        async.flushMicrotasks();
        expect(calls, isEmpty);
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a start sends the content and keepAwake, then counts as running',
        () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(
            title: 'T', body: 'B', keepAwake: true, mayStart: () => true);
        async.flushMicrotasks();
        expect(methods(), ['start']);
        expect(calls.single.arguments,
            {'title': 'T', 'body': 'B', 'keepAwake': true});
        expect(BackgroundServiceManager.isRunning, isTrue);
      });
    });

    test('keepAwake defaults to false, so existing callers stay as they are',
        () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'T', body: 'B');
        async.flushMicrotasks();
        expect(calls.single.arguments,
            {'title': 'T', 'body': 'B', 'keepAwake': false});
      });
    });

    test('a refused start leaves the service counted as stopped', () {
      fakeAsync((async) {
        final logs = captureLogs();
        startReply = () => {'started': false, 'error': 'X'};
        BackgroundServiceManager.startService(title: 'T', body: 'B');
        async.flushMicrotasks();
        expect(BackgroundServiceManager.isRunning, isFalse);
        expect(logs.join('\n'), contains('X'));
      });
    });

    test('a start whose channel call fails does not throw', () {
      fakeAsync((async) {
        startReply = () => throw PlatformException(code: 'boom');
        Object? error;
        BackgroundServiceManager.startService(title: 'T', body: 'B')
            .catchError((Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isNull);
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a stop is always sent, even with nothing counted as running', () {
      fakeAsync((async) {
        // A stop that lands while a start is still on its way to the service.
        expect(BackgroundServiceManager.isRunning, isFalse);
        BackgroundServiceManager.stopService();
        async.flushMicrotasks();
        expect(methods(), ['stop']);
      });
    });

    test('a stop clears the running flag', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'T', body: 'B');
        async.flushMicrotasks();
        expect(BackgroundServiceManager.isRunning, isTrue);
        BackgroundServiceManager.stopService();
        async.flushMicrotasks();
        expect(methods(), ['start', 'stop']);
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a start reply that lands after a stop does not count as running', () {
      fakeAsync((async) {
        final reply = Completer<Object?>();
        startReply = () => reply.future;
        BackgroundServiceManager.startService(title: 'T', body: 'B');
        async.flushMicrotasks();
        expect(methods(), ['start']);

        BackgroundServiceManager.stopService();
        async.flushMicrotasks();
        reply.complete({'started': true, 'error': null});
        async.flushMicrotasks();

        expect(methods(), ['start', 'stop']);
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a stop that fails on the channel does not throw', () {
      fakeAsync((async) {
        messenger.setMockMethodCallHandler(
            channel, (call) async => throw PlatformException(code: 'boom'));
        Object? error;
        BackgroundServiceManager.stopService()
            .catchError((Object e) => error = e);
        async.flushMicrotasks();
        expect(error, isNull);
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('two identical updates send one', () {
      fakeAsync((async) {
        BackgroundServiceManager.updateNotification(
            title: 'T', body: 'B', keepAwake: true);
        BackgroundServiceManager.updateNotification(
            title: 'T', body: 'B', keepAwake: true);
        async.flushMicrotasks();
        expect(methods(), ['update']);
        expect(calls.single.arguments,
            {'title': 'T', 'body': 'B', 'keepAwake': true});
      });
    });

    test('a changed update is sent', () {
      fakeAsync((async) {
        BackgroundServiceManager.updateNotification(title: 'T', body: 'B');
        BackgroundServiceManager.updateNotification(title: 'T', body: 'C');
        async.flushMicrotasks();
        expect(count('update'), 2);
      });
    });

    test('a stop or a start lets the same update through again', () {
      fakeAsync((async) {
        BackgroundServiceManager.updateNotification(title: 'T', body: 'B');
        BackgroundServiceManager.stopService();
        BackgroundServiceManager.updateNotification(title: 'T', body: 'B');
        async.flushMicrotasks();
        expect(count('update'), 2, reason: 'reset by the stop');

        BackgroundServiceManager.startService(title: 'S', body: 'S');
        async.flushMicrotasks();
        BackgroundServiceManager.updateNotification(title: 'T', body: 'B');
        async.flushMicrotasks();
        expect(count('update'), 3, reason: 'reset by the start');
      });
    });

    test('a resume finds the service gone and counts it as stopped', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'T', body: 'B');
        async.flushMicrotasks();
        expect(BackgroundServiceManager.isRunning, isTrue);

        status = {'running': false, 'lastError': null};
        BackgroundServiceManager.healAfterResume(sessionActive: true);
        async.flushMicrotasks();
        expect(BackgroundServiceManager.isRunning, isFalse);
        expect(count('stop'), 0);
      });
    });

    test('a resume with no radio session stops a running service', () {
      fakeAsync((async) {
        status = {'running': true, 'lastError': null};
        BackgroundServiceManager.healAfterResume(sessionActive: false);
        async.flushMicrotasks();
        expect(methods(), ['status', 'stop']);
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a resume keeps a service the radio session still needs', () {
      fakeAsync((async) {
        status = {'running': true, 'lastError': null};
        BackgroundServiceManager.healAfterResume(sessionActive: true);
        async.flushMicrotasks();
        expect(methods(), ['status']);
        expect(BackgroundServiceManager.isRunning, isTrue);
      });
    });

    test('a resume reports an error the service left behind', () {
      fakeAsync((async) {
        final logs = captureLogs();
        status = {'running': false, 'lastError': 'SecurityException: denied'};
        BackgroundServiceManager.healAfterResume(sessionActive: true);
        async.flushMicrotasks();
        expect(logs.join('\n'),
            contains('[BACKGROUND] Service failed to start: SecurityException: '
                'denied'));
      });
    });

    test('the startup cleanup sends stop', () {
      fakeAsync((async) {
        BackgroundServiceManager.cleanupOrphanedService();
        async.flushMicrotasks();
        expect(methods(), ['stop']);
      });
    });

    test('a live stop sends stop', () {
      fakeAsync((async) {
        var done = false;
        BackgroundServiceManager.stopLiveService('exit app')
            .then((_) => done = true);
        async.flushMicrotasks();
        expect(methods(), ['stop']);
        expect(done, isTrue);
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('the status check reports a start that failed in the service', () {
      fakeAsync((async) {
        final logs = captureLogs();
        status = {
          'running': false,
          'lastError': 'ForegroundServiceStartNotAllowedException: background',
        };
        BackgroundServiceManager.startService(title: 'T', body: 'B');
        async.flushMicrotasks();
        expect(BackgroundServiceManager.isRunning, isTrue);

        async.elapse(const Duration(milliseconds: 1400));
        expect(count('status'), 0, reason: 'not before about 1500 ms');
        async.elapse(const Duration(milliseconds: 200));
        expect(count('status'), 1);
        expect(
            logs.join('\n'),
            contains('[BACKGROUND] Service failed to start: '
                'ForegroundServiceStartNotAllowedException: background'));
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('the status check logs nothing when there is no error', () {
      fakeAsync((async) {
        final logs = captureLogs();
        status = {'running': true, 'lastError': null};
        BackgroundServiceManager.startService(title: 'T', body: 'B');
        async.elapse(const Duration(seconds: 2));
        expect(count('status'), 1);
        expect(logs.join('\n'), isNot(contains('Service failed to start')));
        expect(BackgroundServiceManager.isRunning, isTrue);
      });
    });

    test('the status check is skipped after a stop', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'T', body: 'B');
        async.elapse(const Duration(milliseconds: 500));
        BackgroundServiceManager.stopService();
        async.elapse(const Duration(seconds: 5));
        expect(count('status'), 0);
      });
    });

    test('the status check is skipped after another start', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'A', body: 'a');
        async.elapse(const Duration(milliseconds: 1000));
        BackgroundServiceManager.startService(title: 'B', body: 'b');
        async.elapse(const Duration(milliseconds: 1000));
        expect(count('status'), 0, reason: 'the first start check is skipped');
        async.elapse(const Duration(seconds: 1));
        expect(count('status'), 1, reason: 'only the second start checks');
      });
    });
  });

  group('BackgroundServiceManager on the iOS plugin path', () {
    late _FakeService fake;
    late List<MethodCall> channelCalls;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      fake = _FakeService();
      BackgroundServiceManager.debugInstallService(fake);
      channelCalls = [];
      messenger.setMockMethodCallHandler(channel, (call) async {
        channelCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
      BackgroundServiceManager.debugInstallService(null);
      debugDefaultTargetPlatformOverride = null;
    });

    test('a start and a stop go to the plugin, never the session channel', () {
      fakeAsync((async) {
        BackgroundServiceManager.startService(title: 'A', body: 'a');
        async.flushMicrotasks();
        expect(fake.starts, 1);
        expect(BackgroundServiceManager.isRunning, isTrue);

        BackgroundServiceManager.stopService();
        async.flushMicrotasks();
        expect(fake.invoked.last, 'stop');
        expect(BackgroundServiceManager.isRunning, isFalse);
        expect(channelCalls, isEmpty);
      });
    });

    test('a stop that arrives during a start is still honoured', () {
      fakeAsync((async) {
        // The disconnect lands while the plugin is still starting the service.
        fake.onStart = () => BackgroundServiceManager.stopService();
        BackgroundServiceManager.startService(title: 'A', body: 'a');
        async.flushMicrotasks();
        expect(fake.starts, 1);
        expect(fake.invoked.last, 'stop');
        expect(BackgroundServiceManager.isRunning, isFalse);
      });
    });

    test('a live stop leaves iOS alone', () {
      fakeAsync((async) {
        fake.running = true;
        BackgroundServiceManager.stopLiveService('exit app');
        async.flushMicrotasks();
        expect(fake.invoked, isEmpty);
        expect(channelCalls, isEmpty);
      });
    });
  });

  group('Android manifest', () {
    // Comments stripped: they name the removed permissions on purpose.
    final manifest = File('android/app/src/main/AndroidManifest.xml')
        .readAsStringSync()
        .replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

    /// Every element with this tag, as its opening tag's source text.
    List<String> elements(String tag) => RegExp('<$tag\\b[^>]*>')
        .allMatches(manifest)
        .map((m) => m.group(0)!)
        .toList();

    String attribute(String element, String name) =>
        RegExp('$name="([^"]*)"').firstMatch(element)?.group(1) ?? '';

    test('the session service is foreground, private and ends with the task',
        () {
      final service = elements('service').singleWhere(
          (s) => attribute(s, 'android:name') == '.MeshMapperSessionService');
      expect(
        attribute(service, 'android:foregroundServiceType')
            .split('|')
            .toSet(),
        {'location', 'connectedDevice'},
        reason: 'Android throws when startForeground asks for a type the '
            'manifest does not declare for the service',
      );
      expect(attribute(service, 'android:stopWithTask'), 'true',
          reason: 'swiping the app away must end the session');
      expect(attribute(service, 'android:exported'), 'false');
    });

    test("the plugin's service and receivers are removed", () {
      const removed = [
        'id.flutter.flutter_background_service.BackgroundService',
        'id.flutter.flutter_background_service.WatchdogReceiver',
        'id.flutter.flutter_background_service.BootReceiver',
      ];
      final components = [...elements('service'), ...elements('receiver')];
      for (final name in removed) {
        final element = components
            .where((e) => attribute(e, 'android:name') == name)
            .toList();
        expect(element, hasLength(1), reason: name);
        expect(attribute(element.single, 'tools:node'), 'remove',
            reason: '$name would merge back in from the plugin');
      }
    });

    test('neither dataSync nor the boot permission is granted', () {
      final permissions = elements('uses-permission');
      String? node(String permission) => permissions
          .where((p) =>
              attribute(p, 'android:name') == 'android.permission.$permission')
          .map((p) => attribute(p, 'tools:node'))
          .firstOrNull;

      expect(node('FOREGROUND_SERVICE_DATA_SYNC'), isNull,
          reason: 'no service starts with dataSync any more');
      expect(node('RECEIVE_BOOT_COMPLETED'), 'remove',
          reason: 'only the plugin adds it, for the boot start that is gone');
      expect(manifest, isNot(contains('dataSync')));
    });
  });
}

class _FakeService implements FlutterBackgroundService {
  bool running = false;
  int starts = 0;
  void Function()? onStart;
  final List<String> invoked = [];

  @override
  Future<bool> startService() async {
    starts++;
    running = true;
    onStart?.call();
    return true;
  }

  @override
  Future<bool> isRunning() async => running;

  @override
  void invoke(String method, [Map<String, dynamic>? arg]) {
    invoked.add(method);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
