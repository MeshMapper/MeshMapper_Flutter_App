import 'dart:convert';

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

    test('heard time survives a rebuild without changing the fingerprint', () {
      const heardAtMs = 1759999980000.0;
      WatchSnapshot withBuildTime(int updatedAtMs) => WatchSnapshot(
            core: _snapshot().core,
            geo: WatchGeo(
              pings: const [],
              repeaters: const [],
              heard: [
                WatchHeardNode(
                  id: '4E5D',
                  name: 'Capitol Hill',
                  snr: 8.5,
                  at: DateTime.fromMillisecondsSinceEpoch(1759999980000),
                  typeColor: const WatchColor(0, 1, 0),
                ),
              ],
              linkedRepeaterIds: const [],
            ),
            controls: _snapshot().controls,
            updatedAt: DateTime.fromMillisecondsSinceEpoch(updatedAtMs),
          );

      String fingerprint(WatchSnapshot snapshot) {
        final payload = Map<String, Object?>.from(snapshot.toMap())
          ..remove('updatedAtMs');
        return jsonEncode(payload);
      }

      final first = withBuildTime(1759999999000);
      final rebuilt = withBuildTime(1760000000000);
      final heard = (first.toMap()['geo'] as Map)['heard'] as List;
      expect((heard.first as Map)['atMs'], heardAtMs);
      expect(fingerprint(rebuilt), fingerprint(first));
    });

    test('repeater wire object carries both database and hex identities', () {
      const repeater = WatchRepeater(
        id: '01',
        hexId: '4E5D82',
        name: 'Capitol Hill',
        lat: 47.6,
        lon: -122.3,
        color: WatchColor(1, 0, 0),
        heardThisCycle: true,
      );

      expect(repeater.toMap().keys.toSet(), {
        'id',
        'hexId',
        'name',
        'lat',
        'lon',
        'color',
        'heardThisCycle',
      });
    });

    test('phase duration rides along so the watch can draw its own bar', () {
      // Deadline plus duration is everything needed to compute the remaining
      // fraction locally, which is why the bar needs no per-second updates.
      expect(
          _snapshot(phaseDurationMs: 45000).toMap()['phaseDurationMs'], 45000);
      expect(_snapshot().toMap()['phaseDurationMs'], isNull);
    });

    test('wire version is stamped so the watch can refuse unknown payloads',
        () {
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
    late bool nativeAvailable;
    late bool syncSucceeds;
    late int syncCalls;

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      channel = const MethodChannel('meshmapper/watch_test');
      bridge = WatchBridgeService(channel: channel);
      handled = [];
      nativeAvailable = true;
      syncSucceeds = true;
      syncCalls = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          return {
            'activated': nativeAvailable,
            'paired': nativeAvailable,
            'installed': nativeAvailable,
          };
        }
        if (call.method == 'sync') {
          syncCalls++;
          return syncSucceeds;
        }
        return null;
      });
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      bridge.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
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

    test('availability can open after attach without an app restart', () async {
      nativeAvailable = false;
      final changes = <bool>[];
      bridge.attachCommandHandler(
        (_) => null,
        onAvailabilityChanged: changes.add,
      );
      await Future<void>.delayed(Duration.zero);
      expect(bridge.canSync, isFalse);
      var builds = 0;
      bridge.schedule(
        () {
          builds++;
          return _snapshot();
        },
        urgencyKeyBuilder: () => _snapshot().urgencyKey,
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(builds, 0,
          reason: 'an iPhone without a watch must not construct geo payloads');

      final result = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall(
          'availabilityChanged',
          {'activated': true, 'paired': true, 'installed': true},
        )),
        null,
      );
      expect(result, isNotNull);
      expect(bridge.canSync, isTrue);
      expect(changes, [true]);
    });

    test('a native false is not cached as a delivered snapshot', () async {
      bridge.attachCommandHandler((_) => null);
      await Future<void>.delayed(Duration.zero);
      syncSucceeds = false;
      var builds = 0;

      void schedule() => bridge.schedule(
            () {
              builds++;
              return _snapshot();
            },
            urgencyKeyBuilder: () => _snapshot().urgencyKey,
            immediate: true,
          );

      schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(builds, 2);
      expect(syncCalls, 2,
          reason: 'native refused both; neither payload was delivered');
    });

    test('a watch state change resends even when availability stays true',
        () async {
      bridge.attachCommandHandler((_) => null);
      await Future<void>.delayed(Duration.zero);
      var builds = 0;

      void schedule() => bridge.schedule(
            () {
              builds++;
              return _snapshot();
            },
            urgencyKeyBuilder: () => _snapshot().urgencyKey,
            immediate: true,
          );

      schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(syncCalls, 1);

      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall(
          'availabilityChanged',
          {'activated': true, 'paired': true, 'installed': true},
        )),
        null,
      );
      schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(builds, 2);
      expect(syncCalls, 2,
          reason: 'native cleared its context cache on the state change');
    });

    test('the nonurgent throttle runs before the snapshot builder', () async {
      bridge.attachCommandHandler((_) => null);
      await Future<void>.delayed(Duration.zero);
      var builds = 0;

      void schedule() => bridge.schedule(
            () {
              builds++;
              return _snapshot();
            },
            urgencyKeyBuilder: () => _snapshot().urgencyKey,
            immediate: true,
          );

      schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(builds, 1,
          reason: 'geo construction waits until the throttle window opens');
      expect(syncCalls, 1);
    });

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

    test('an unknown command is refused without reaching the handler',
        () async {
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
