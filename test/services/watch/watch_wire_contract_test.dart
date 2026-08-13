import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/watch/watch_bridge_service.dart';
import 'package:mesh_mapper/services/watch/watch_models.dart';

/// These tests guard the Dart↔Swift contract.
///
/// `ios/Shared/MeshMapperWatchPayload.swift` decodes this JSON with a synthesised
/// `Codable`, which matches on exact key names. A rename on either side compiles
/// fine and fails silently at runtime on the wrist — so the key set is asserted
/// here rather than trusted.
WatchSnapshot _snapshot({
  WatchHapticCue? cue,
  String phaseTitle = 'Listening',
  bool isConnected = true,
  int? phaseDurationMs,
}) =>
    WatchSnapshot(
      core: LiveActivitySnapshot(
        sessionId: 'session-1',
        mode: 'Active',
        phase: LiveActivityPhase.listening,
        phaseTitle: phaseTitle,
        phaseDetail: 'Waiting for echoes',
        phaseEndsAt: DateTime.fromMillisecondsSinceEpoch(1760000000000),
        isConnected: isConnected,
        zoneCode: 'SEA',
        txCount: 3,
        rxCount: 2,
        discoveryCount: 1,
        traceCount: 0,
        queueSize: 4,
        repeaters: const [],
        totalHeardCount: 0,
        repeatersAreCurrent: true,
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1759999999000),
      ),
      geo: const WatchGeo(
        pings: [],
        repeaters: [],
        heard: [],
        linkedRepeaterIds: [],
      ),
      controls: const WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: true,
      ),
      pingColor: const WatchColor(1, 0, 0),
      phaseDurationMs: phaseDurationMs,
      cue: cue,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(1759999999000),
    );

void main() {
  group('wire contract', () {
    test('top-level keys match the Swift WatchSnapshot', () {
      final map = _snapshot().toMap();

      expect(
        map.keys.toSet(),
        {
          'wireVersion',
          'sessionId',
          'mode',
          'phase',
          'phaseTitle',
          'phaseDetail',
          'phaseEndsAtMs',
          'phaseDurationMs',
          'isConnected',
          'zoneCode',
          'txCount',
          'rxCount',
          'discoveryCount',
          'traceCount',
          'queueSize',
          'pingColor',
          'geo',
          'controls',
          'cue',
          'updatedAtMs',
        },
      );
    });

    test('nested keys match the Swift structs', () {
      final map = _snapshot().toMap();

      expect(
        (map['geo']! as Map).keys.toSet(),
        {'you', 'pings', 'repeaters', 'heard', 'linkedRepeaterIds'},
      );
      expect(
        (map['controls']! as Map).keys.toSet(),
        {
          'canStartStop',
          'canManualPing',
          'isSessionActive',
          'manualCooldownEndsAtMs',
          'blockedReason',
        },
      );
      expect((map['pingColor']! as Map).keys.toSet(), {'r', 'g', 'b'});
    });

    test('timestamps are epoch milliseconds as doubles', () {
      final map = _snapshot().toMap();
      expect(map['updatedAtMs'], isA<double>());
      expect(map['phaseEndsAtMs'], 1760000000000.0);
    });

    test('phase duration rides along so the watch can draw its own bar', () {
      // Deadline plus duration is everything needed to compute the remaining
      // fraction locally, which is why the bar needs no per-second updates.
      expect(_snapshot(phaseDurationMs: 45000).toMap()['phaseDurationMs'], 45000);
      expect(_snapshot().toMap()['phaseDurationMs'], isNull);
    });

    test('wire version is stamped so the watch can refuse unknown payloads', () {
      expect(_snapshot().toMap()['wireVersion'], WatchWire.version);
    });

    test('urgency key ignores geo but tracks phase, controls, and cues', () {
      final base = _snapshot();
      expect(_snapshot().urgencyKey, base.urgencyKey);

      expect(
        _snapshot(phaseTitle: 'Sending').urgencyKey,
        isNot(base.urgencyKey),
      );
      expect(
        _snapshot(isConnected: false).urgencyKey,
        isNot(base.urgencyKey),
      );
      expect(
        _snapshot(cue: const WatchHapticCue(id: 'c1', kind: 'success'))
            .urgencyKey,
        isNot(base.urgencyKey),
      );
    });
  });

  group('command kinds', () {
    test('round-trip through the wire names Swift sends', () {
      for (final kind in WatchCommandKind.values) {
        expect(WatchCommandKind.fromWire(kind.name), kind);
      }
    });

    test('an unknown command is rejected rather than guessed at', () {
      expect(WatchCommandKind.fromWire('selfDestruct'), isNull);
    });
  });

  group('bridge command handling', () {
    late WatchBridgeService bridge;
    late MethodChannel channel;
    late List<WatchCommandKind> handled;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      channel = const MethodChannel('meshmapper/watch_test');
      bridge = WatchBridgeService(channel: channel);
      handled = [];
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      bridge.dispose();
    });

    Future<Map<Object?, Object?>?> sendCommand(String id, String kind) async {
      final result = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('command', {'id': id, 'kind': kind}),
        ),
        null,
      );
      if (result == null) return null;
      return channel.codec.decodeEnvelope(result) as Map<Object?, Object?>?;
    }

    test('accepted commands reach the handler', () async {
      bridge.attachCommandHandler((kind) async {
        handled.add(kind);
        return null;
      });

      final reply = await sendCommand('cmd-1', 'manualPing');

      expect(handled, [WatchCommandKind.manualPing]);
      expect(reply?['accepted'], isTrue);
    });

    test('a redelivered command does not transmit twice', () async {
      bridge.attachCommandHandler((kind) async {
        handled.add(kind);
        return null;
      });

      await sendCommand('cmd-1', 'manualPing');
      await sendCommand('cmd-1', 'manualPing');

      expect(handled, hasLength(1),
          reason: 'WatchConnectivity redelivers; a second ping must not fire');
    });

    test('a refused command may be retried once conditions change', () async {
      var refuse = true;
      bridge.attachCommandHandler((kind) async {
        handled.add(kind);
        return refuse ? 'Not connected' : null;
      });

      final first = await sendCommand('cmd-2', 'startSession');
      expect(first?['accepted'], isFalse);
      expect(first?['reason'], 'Not connected');

      refuse = false;
      final second = await sendCommand('cmd-2', 'startSession');
      expect(second?['accepted'], isTrue);
      expect(handled, hasLength(2));
    });

    test('an unknown command is refused without reaching the handler', () async {
      bridge.attachCommandHandler((kind) async {
        handled.add(kind);
        return null;
      });

      final reply = await sendCommand('cmd-3', 'selfDestruct');

      expect(handled, isEmpty);
      expect(reply?['accepted'], isFalse);
    });

    test('a handler that throws refuses rather than crashing the bridge',
        () async {
      bridge.attachCommandHandler((kind) async => throw StateError('boom'));

      final reply = await sendCommand('cmd-4', 'manualPing');

      expect(reply?['accepted'], isFalse);
      expect(reply?['reason'], 'Command failed');
    });
  });
}
