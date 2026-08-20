import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_service.dart';

LiveActivitySnapshot _snapshot({
  LiveActivityPhase phase = LiveActivityPhase.listeningDiscovery,
  int rxCount = 2,
}) =>
    LiveActivitySnapshot(
      sessionId: 'session-1',
      mode: 'Passive',
      phase: phase,
      phaseTitle: 'Listening…',
      isConnected: true,
      txCount: 0,
      rxCount: rxCount,
      discoveryCount: 1,
      traceCount: 0,
      queueSize: 0,
      repeaters: const [],
      totalHeardCount: 0,
      repeatersAreCurrent: true,
      updatedAt: DateTime.utc(2026, 8, 13),
    );

/// The cheap projection the service preflights on, derived from a built
/// snapshot so a test reads the same way the provider's builder does.
String _preflightKey(LiveActivitySnapshot snapshot) =>
    LiveActivitySnapshot.buildPreflightUrgencyKey(
      sessionId: snapshot.sessionId,
      mode: snapshot.mode,
      phase: snapshot.phase,
      phaseTitle: snapshot.phaseTitle,
      phaseDetail: snapshot.phaseDetail,
      phaseEndsAt: snapshot.phaseEndsAt,
      phaseDurationMs: snapshot.phaseDurationMs,
      isConnected: snapshot.isConnected,
      zoneCode: snapshot.zoneCode,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('unavailable Live Activities retry within the same session', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('meshmapper/live_activity_retry_test');
    var syncCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'sync') return null;
      syncCalls++;
      return syncCalls > 1;
    });
    final service = LiveActivityService(
      channel: channel,
      unavailableRetryDelay: const Duration(milliseconds: 20),
    );
    addTearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    service.schedule(
      _snapshot,
      urgencyKeyBuilder: () => _preflightKey(_snapshot()),
      immediate: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(syncCalls, 2,
        reason: 'enabling the feature must not require a new session ID');
  });

  test('counter churn waits out the non-urgent interval', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('meshmapper/live_activity_throttle_test');
    final phases = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'sync') return null;
      phases.add((call.arguments as Map)['phase'] as String);
      return true;
    });
    final service = LiveActivityService(
      channel: channel,
      minimumNonUrgentInterval: const Duration(seconds: 30),
    );
    addTearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    service.schedule(
      _snapshot,
      urgencyKeyBuilder: () => _preflightKey(_snapshot()),
      immediate: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    // A changed RX count is real, but nobody is waiting on it.
    service.schedule(
      () => _snapshot(rxCount: 3),
      urgencyKeyBuilder: () => _preflightKey(_snapshot(rxCount: 3)),
      immediate: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(phases, ['listening_discovery'],
        reason: 'a counter change alone must not reach ActivityKit');

    // A phase change is news, and news is not throttled.
    service.schedule(
      () => _snapshot(phase: LiveActivityPhase.waitingDiscovery, rxCount: 3),
      urgencyKeyBuilder: () =>
          _preflightKey(_snapshot(phase: LiveActivityPhase.waitingDiscovery)),
      immediate: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(phases, ['listening_discovery', 'waiting_discovery']);
  });

  test('an unsupported host is asked once, not every 30 s for a session',
      () async {
    // iOS below 16.2 cannot show a Live Activity and never will while the app
    // is running, but it answered the same way as "authorization is off" — so
    // it earned the same 30 s retry, forever, on a device that was never going
    // to display anything.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('meshmapper/live_activity_unsupported_test');
    var syncCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method != 'sync') return null;
      syncCalls++;
      return LiveActivityService.unsupportedHost;
    });
    final service = LiveActivityService(
      channel: channel,
      unavailableRetryDelay: const Duration(milliseconds: 20),
      minimumNonUrgentInterval: const Duration(milliseconds: 20),
    );
    addTearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    service.schedule(
      _snapshot,
      urgencyKeyBuilder: () => _preflightKey(_snapshot()),
      immediate: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(syncCalls, 1);

    // Everything that would normally re-arm it: the retry it used to schedule,
    // and a caller that keeps scheduling regardless.
    for (var tick = 0; tick < 4; tick++) {
      service.schedule(
        () => _snapshot(rxCount: tick),
        urgencyKeyBuilder: () =>
            _preflightKey(_snapshot(phase: LiveActivityPhase.waitingDiscovery)),
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    expect(syncCalls, 1,
        reason: 'a host that cannot host one must be asked exactly once');
  });

  test('a missing channel also stops for good', () async {
    // The other permanent condition: an iOS project generated before this
    // feature existed has no such channel, and will not grow one at runtime.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('meshmapper/live_activity_missing_test');
    var syncCalls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'sync') syncCalls++;
      throw MissingPluginException('no channel');
    });
    final service = LiveActivityService(
      channel: channel,
      minimumNonUrgentInterval: const Duration(milliseconds: 20),
    );
    addTearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    for (var tick = 0; tick < 4; tick++) {
      service.schedule(
        () => _snapshot(rxCount: tick),
        urgencyKeyBuilder: () => _preflightKey(_snapshot(rxCount: tick)),
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 30));
    }

    expect(syncCalls, 1,
        reason: 'a host with no channel must be asked exactly once');
  });

  test('a throttled flush costs nothing to build', () async {
    // The 500 ms countdown listenable asks for a flush twice a second for the
    // length of a session, and building a snapshot walks the whole TX, RX,
    // discovery and trace history to resolve the latest ping colour. The
    // throttle has to be decided before any of that, not after.
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('meshmapper/live_activity_preflight_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => true);
    final service = LiveActivityService(
      channel: channel,
      minimumNonUrgentInterval: const Duration(seconds: 30),
    );
    addTearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    var builds = 0;
    final steadyKey = _preflightKey(_snapshot());
    LiveActivitySnapshot? countedBuild() {
      builds++;
      return _snapshot(rxCount: builds);
    }

    service.schedule(
      countedBuild,
      urgencyKeyBuilder: () => steadyKey,
      immediate: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(builds, 1);

    for (var tick = 0; tick < 5; tick++) {
      service.schedule(
        countedBuild,
        urgencyKeyBuilder: () => steadyKey,
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(builds, 1,
        reason: 'a tick that changes nothing urgent must not build a snapshot');

    // News still bypasses the floor, and still pays to build.
    final news = _snapshot(phase: LiveActivityPhase.waitingDiscovery);
    service.schedule(
      () {
        builds++;
        return news;
      },
      urgencyKeyBuilder: () => _preflightKey(news),
      immediate: true,
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(builds, 2, reason: 'a phase change is news and is never deferred');
  });
}
