import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_service.dart';

LiveActivitySnapshot _snapshot() => LiveActivitySnapshot(
      sessionId: 'session-1',
      mode: 'Passive',
      phase: LiveActivityPhase.listeningDiscovery,
      phaseTitle: 'Listening…',
      isConnected: true,
      txCount: 0,
      rxCount: 2,
      discoveryCount: 1,
      traceCount: 0,
      queueSize: 0,
      repeaters: const [],
      totalHeardCount: 0,
      repeatersAreCurrent: true,
      updatedAt: DateTime.utc(2026, 8, 13),
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

    service.schedule(_snapshot, immediate: true);
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(syncCalls, 2,
        reason: 'enabling the feature must not require a new session ID');
  });
}
