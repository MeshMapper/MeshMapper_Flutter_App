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
  WatchGeo? geo,
  bool mapGeoIncluded = true,
  List<WatchStartMode> availableStartModes = const [WatchStartMode.passive],
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
      geo: geo ??
          const WatchGeo(
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
      mapGeoIncluded: mapGeoIncluded,
      availableStartModes: availableStartModes,
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
          'mapGeoIncluded',
          'availableStartModes',
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
          'manualPingApplicable',
          'manualCooldownEndsAtMs',
          'blockedReason',
        },
      );
      expect((map['pingColor']! as Map).keys.toSet(), {'r', 'g', 'b'});
    });

    test('full snapshots retain every geography field', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1759999980000);
      final geo = WatchGeo(
        you: WatchPosition(lat: 47.6, lon: -122.3, fixedAt: at),
        pings: [
          WatchPing(
            id: 'ping-1',
            lat: 47.61,
            lon: -122.31,
            kind: 'tx',
            color: const WatchColor(0, 1, 0),
            at: at,
          ),
        ],
        repeaters: const [
          WatchRepeater(
            id: 'database-1',
            hexId: '4E5D82',
            name: 'Capitol Hill',
            lat: 47.62,
            lon: -122.32,
            color: WatchColor(1, 0, 1),
            heardThisCycle: true,
          ),
        ],
        heard: [
          WatchHeardNode(
            id: '4E5D',
            typeColor: const WatchColor(0, 1, 0),
            at: at,
          ),
        ],
        linkedRepeaterIds: const ['database-1'],
      );
      final map = _snapshot(geo: geo).toMap();
      final encodedGeo = map['geo']! as Map;

      expect(map['mapGeoIncluded'], isTrue);
      expect(encodedGeo['you'], isNotNull);
      expect(encodedGeo['pings'], hasLength(1));
      expect(encodedGeo['repeaters'], hasLength(1));
      expect(encodedGeo['heard'], hasLength(1));
      expect(encodedGeo['linkedRepeaterIds'], ['database-1']);
    });

    test('suppressed snapshots clear only map detail', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1759999980000);
      final geo = WatchGeo(
        you: WatchPosition(lat: 47.6, lon: -122.3, fixedAt: at),
        pings: [
          WatchPing(
            id: 'ping-1',
            lat: 47.61,
            lon: -122.31,
            kind: 'tx',
            color: const WatchColor(0, 1, 0),
            at: at,
          ),
        ],
        repeaters: const [
          WatchRepeater(
            id: 'database-1',
            hexId: '4E5D82',
            name: 'Capitol Hill',
            lat: 47.62,
            lon: -122.32,
            color: WatchColor(1, 0, 1),
            heardThisCycle: true,
          ),
        ],
        heard: [
          WatchHeardNode(
            id: '4E5D',
            typeColor: const WatchColor(0, 1, 0),
            at: at,
          ),
        ],
        linkedRepeaterIds: const ['database-1'],
      );
      final map = _snapshot(geo: geo, mapGeoIncluded: false).toMap();
      final encodedGeo = map['geo']! as Map;

      expect(map['mapGeoIncluded'], isFalse);
      expect(encodedGeo['you'], isNotNull,
          reason: 'the fix is cheap and remains useful state');
      expect(encodedGeo['heard'], hasLength(1),
          reason: 'the readout consumes Top Heard');
      expect(encodedGeo['pings'], isEmpty);
      expect(encodedGeo['repeaters'], isEmpty);
      expect(encodedGeo['linkedRepeaterIds'], isEmpty);
    });

    test('old payload semantics default map geography to included', () {
      expect(_snapshot().mapGeoIncluded, isTrue);
      expect(_snapshot().toMap()['mapGeoIncluded'], isTrue);
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

    test('failure cues carry their creation time for restart filtering', () {
      final issuedAt = DateTime.utc(2026, 8, 12, 10);
      final cue = WatchHapticCue(
        id: 'failure-1',
        kind: 'failure',
        issuedAt: issuedAt,
        message: 'Could not start',
      );

      expect(cue.toMap(), {
        'id': 'failure-1',
        'kind': 'failure',
        'issuedAtMs': issuedAt.millisecondsSinceEpoch.toDouble(),
        'message': 'Could not start',
      });
    });

    test('phase duration rides along so the watch can draw its own bar', () {
      // Deadline plus duration is everything needed to compute the remaining
      // fraction locally, which is why the bar needs no per-second updates.
      expect(
          _snapshot(phaseDurationMs: 45000).toMap()['phaseDurationMs'], 45000);
      expect(_snapshot().toMap()['phaseDurationMs'], isNull);
    });

    test('snapshot carries phone-resolved start modes', () {
      expect(
        _snapshot(
          availableStartModes: const [
            WatchStartMode.passive,
            WatchStartMode.hybrid,
          ],
        ).toMap()['availableStartModes'],
        ['passive', 'hybrid'],
      );
    });

    test('old controls default manual ping slot ownership to false', () {
      const controls = WatchControls(
        canStartStop: true,
        canManualPing: true,
        isSessionActive: true,
      );

      expect(controls.manualPingApplicable, isFalse);
      expect(controls.toMap()['manualPingApplicable'], isFalse);
    });

    test('controls serialize stable manual ping slot ownership', () {
      const controls = WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: true,
        manualPingApplicable: true,
      );

      expect(controls.toMap()['manualPingApplicable'], isTrue);
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
        _snapshot(
          cue: WatchHapticCue(
            id: 'c1',
            kind: 'success',
            issuedAt: DateTime.utc(2026, 8, 12),
          ),
        ).urgencyKey,
        isNot(base.urgencyKey),
      );
    });
  });

  group('command kinds', () {
    SessionStartAvailability startAvailability({
      bool isTransmitMode = true,
      bool isConnected = true,
      bool antennaConfigured = true,
      bool powerConfigured = true,
      bool isPendingDisable = false,
      bool isTargetedRunning = false,
      bool isAutoStarting = false,
      bool cooldownActive = false,
      bool isPingSending = false,
      bool rxWindowActive = false,
      bool txBlockedByOffline = false,
      bool txNotAllowed = false,
      String? transmitValidationReason,
    }) =>
        resolveSessionStartAvailability(
          isTransmitMode: isTransmitMode,
          isConnected: isConnected,
          antennaConfigured: antennaConfigured,
          powerConfigured: powerConfigured,
          isPendingDisable: isPendingDisable,
          isTargetedRunning: isTargetedRunning,
          isAutoStarting: isAutoStarting,
          cooldownActive: cooldownActive,
          isPingSending: isPingSending,
          rxWindowActive: rxWindowActive,
          txBlockedByOffline: txBlockedByOffline,
          txNotAllowed: txNotAllowed,
          transmitValidationReason: transmitValidationReason,
        );

    test('round-trip through the wire names Swift sends', () {
      for (final kind in WatchCommandKind.values) {
        expect(WatchCommandKind.fromWire(kind.name), kind);
      }
    });

    test('an unknown command is rejected rather than guessed at', () {
      expect(WatchCommandKind.fromWire('selfDestruct'), isNull);
    });

    test('Start is idempotent while starting but Stop tells the truth', () {
      final start = resolveWatchSessionCommandAdmission(
        kind: WatchCommandKind.startSession,
        isSessionActive: false,
        isSessionStarting: true,
      );
      final stop = resolveWatchSessionCommandAdmission(
        kind: WatchCommandKind.stopSession,
        isSessionActive: false,
        isSessionStarting: true,
      );

      expect(start, (shouldRun: false, refusal: null));
      expect(stop.shouldRun, isFalse);
      expect(stop.refusal, 'Still starting — try Stop again');
    });

    test('only the always-present watch projects shared Starting to idle', () {
      const sharedLiveActivityPhase = LiveActivityPhase.starting;

      expect(
        resolveWatchSurfacePhase(
          sharedPhase: sharedLiveActivityPhase,
          isSessionActive: false,
          isSessionStarting: false,
        ),
        LiveActivityPhase.idle,
      );
      expect(sharedLiveActivityPhase, LiveActivityPhase.starting,
          reason: 'the Live Activity consumes the shared resolver directly');
      expect(
        resolveWatchSurfacePhase(
          sharedPhase: sharedLiveActivityPhase,
          isSessionActive: false,
          isSessionStarting: true,
        ),
        LiveActivityPhase.starting,
      );
    });

    test('Hybrid is refused when current zone policy forbids TX', () {
      final result = resolveWatchRequestedStartMode(
        requestedMode: 'hybrid',
        isConnected: true,
        txAllowed: false,
      );

      expect(result.mode, isNull);
      expect(result.refusal, 'Passive Only');
    });

    test('an omitted start mode preserves the established phone fallback', () {
      final result = resolveWatchRequestedStartMode(
        requestedMode: null,
        isConnected: true,
        txAllowed: false,
      );

      expect(result, (mode: null, refusal: null));
    });

    test('start admission names every shared blocked precondition', () {
      final blocked = <String, SessionStartAvailability>{
        'Not connected': startAvailability(isConnected: false),
        'Still stopping': startAvailability(isPendingDisable: true),
        'Trace session active': startAvailability(isTargetedRunning: true),
        'Already starting': startAvailability(isAutoStarting: true),
        'Select antenna option': startAvailability(antennaConfigured: false),
        'Select power level': startAvailability(powerConfigured: false),
        'Offline Mode': startAvailability(txBlockedByOffline: true),
        'Passive Only': startAvailability(txNotAllowed: true),
        'Cooling down': startAvailability(cooldownActive: true),
        'Ping in progress': startAvailability(isPingSending: true),
        'Listening for ping response': startAvailability(rxWindowActive: true),
        'Waiting for GPS lock': startAvailability(
          transmitValidationReason: 'Waiting for GPS lock',
        ),
      };

      for (final entry in blocked.entries) {
        expect(entry.value.allowed, isFalse, reason: entry.key);
        expect(entry.value.reason, entry.key);
      }
    });

    test('Passive ignores blockers that only constrain a transmitting start',
        () {
      final passive = startAvailability(
        isTransmitMode: false,
        cooldownActive: true,
        isPingSending: true,
        rxWindowActive: true,
        txBlockedByOffline: true,
        txNotAllowed: true,
        transmitValidationReason: 'Waiting for GPS lock',
      );

      expect(passive, (allowed: true, reason: null));
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
            'supported': true,
            'activated': nativeAvailable,
            'paired': nativeAvailable,
            'installed': nativeAvailable,
            'reachable': nativeAvailable,
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

    Future<Map<Object?, Object?>?> sendCommand(
      String id,
      String kind, {
      String? mode,
      bool? mapGeoNeeded,
      double? issuedAtMs,
    }) async {
      final result = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(
          MethodCall('command', {
            'id': id,
            'kind': kind,
            if (mode != null) 'mode': mode,
            if (mapGeoNeeded != null) 'mapGeoNeeded': mapGeoNeeded,
            if (issuedAtMs != null) 'issuedAtMs': issuedAtMs,
          }),
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
          {
            'supported': true,
            'activated': true,
            'paired': true,
            'installed': true,
            'reachable': true,
          },
        )),
        null,
      );
      expect(result, isNotNull);
      expect(bridge.canSync, isTrue);
      expect(changes, [true]);
    });

    test('diagnostics identify the exact condition closing the sync gate',
        () async {
      bridge.attachCommandHandler((_) => null);
      await Future<void>.delayed(Duration.zero);

      final result = await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        channel.name,
        channel.codec.encodeMethodCall(const MethodCall(
          'availabilityChanged',
          {
            'supported': true,
            'activated': true,
            'paired': true,
            'installed': false,
            'reachable': true,
          },
        )),
        null,
      );

      expect(result, isNotNull);
      expect(bridge.canSync, isFalse);
      expect(bridge.diagnostics.value.supported, isTrue);
      expect(bridge.diagnostics.value.reachable, isTrue);
      expect(bridge.diagnostics.value.failingSyncConditions, ['installed']);
      expect(bridge.diagnostics.value.lastAvailabilityChangedAt, isNotNull);
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
      expect(bridge.diagnostics.value.lastSendDelivered, isFalse);
      expect(bridge.diagnostics.value.lastSuccessfulSendAt, isNull);
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
          {
            'supported': true,
            'activated': true,
            'paired': true,
            'installed': true,
            'reachable': true,
          },
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

    test('successful native delivery reports the exact snapshot once',
        () async {
      WatchSnapshot? delivered;
      bridge.attachCommandHandler(
        (_) => null,
        onSnapshotDelivered: (snapshot) => delivered = snapshot,
      );
      await Future<void>.delayed(Duration.zero);
      final snapshot = _snapshot();

      bridge.schedule(
        () => snapshot,
        urgencyKeyBuilder: () => snapshot.urgencyKey,
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

      expect(delivered, same(snapshot));
      expect(syncCalls, 1);
      expect(bridge.diagnostics.value.lastSendDelivered, isTrue);
      expect(bridge.diagnostics.value.lastSuccessfulSendAt, isNotNull);
    });

    test('accepted commands reach the handler', () async {
      bridge.attachCommandHandler((command) async {
        handled.add(command.kind);
        return null;
      });

      final reply = await sendCommand('cmd-1', 'manualPing');

      expect(handled, [WatchCommandKind.manualPing]);
      expect(reply?['accepted'], isTrue);
    });

    test('fresh map demand suppresses and restores geography', () async {
      bridge.attachCommandHandler((_) => null);
      final nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();

      await sendCommand(
        'geo-off',
        'requestSnapshot',
        mapGeoNeeded: false,
        issuedAtMs: nowMs,
      );
      expect(bridge.shouldIncludeMapGeo, isFalse);

      await sendCommand(
        'geo-on',
        'requestSnapshot',
        mapGeoNeeded: true,
      );
      expect(bridge.shouldIncludeMapGeo, isTrue);
    });

    test('stale suppression cannot blank a newly visible map', () async {
      bridge.attachCommandHandler((_) => null);
      final staleMs = DateTime.now()
          .subtract(const Duration(seconds: 45))
          .millisecondsSinceEpoch
          .toDouble();

      await sendCommand(
        'stale-geo-off',
        'requestSnapshot',
        mapGeoNeeded: false,
        issuedAtMs: staleMs,
      );

      expect(bridge.shouldIncludeMapGeo, isTrue);
    });

    test('an older queued suppression cannot overtake map demand', () async {
      bridge.attachCommandHandler((_) => null);
      final nowMs = DateTime.now().millisecondsSinceEpoch.toDouble();

      await sendCommand(
        'new-geo-on',
        'requestSnapshot',
        mapGeoNeeded: true,
        issuedAtMs: nowMs,
      );
      await sendCommand(
        'old-geo-off',
        'requestSnapshot',
        mapGeoNeeded: false,
        issuedAtMs: nowMs - 1000,
      );

      expect(bridge.shouldIncludeMapGeo, isTrue);
    });

    test('a redelivered command does not transmit twice', () async {
      bridge.attachCommandHandler((command) async {
        handled.add(command.kind);
        return null;
      });

      await sendCommand('cmd-1', 'manualPing');
      await sendCommand('cmd-1', 'manualPing');

      expect(handled, hasLength(1),
          reason: 'WatchConnectivity redelivers; a second ping must not fire');
    });

    test('a refused command may be retried once conditions change', () async {
      var refuse = true;
      bridge.attachCommandHandler((command) async {
        handled.add(command.kind);
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
      bridge.attachCommandHandler((command) async {
        handled.add(command.kind);
        return null;
      });

      final reply = await sendCommand('cmd-3', 'selfDestruct');

      expect(handled, isEmpty);
      expect(reply?['accepted'], isFalse);
    });

    test('a handler that throws refuses rather than crashing the bridge',
        () async {
      bridge.attachCommandHandler((command) async => throw StateError('boom'));

      final reply = await sendCommand('cmd-4', 'manualPing');

      expect(reply?['accepted'], isFalse);
      expect(reply?['reason'], 'Command failed');
    });

    test('a start command carries its requested mode to admission', () async {
      WatchCommand? received;
      bridge.attachCommandHandler((command) {
        received = command;
        return null;
      });

      final reply = await sendCommand(
        'cmd-mode',
        'startSession',
        mode: 'hybrid',
      );

      expect(reply?['accepted'], isTrue);
      expect(received?.kind, WatchCommandKind.startSession);
      expect(received?.mode, 'hybrid');
    });

    test('a forbidden requested mode returns the phone refusal', () async {
      bridge.attachCommandHandler((command) {
        return resolveWatchRequestedStartMode(
          requestedMode: command.mode,
          isConnected: true,
          txAllowed: false,
        ).refusal;
      });

      final reply = await sendCommand(
        'cmd-forbidden-mode',
        'startSession',
        mode: 'hybrid',
      );

      expect(reply?['accepted'], isFalse);
      expect(reply?['reason'], 'Passive Only');
    });
  });

  /// The gate that stops a parked phone streaming GPS jitter at the watch, and
  /// the reason it lives in the transport rather than in the payload builder.
  ///
  /// It used to be applied by handing the watch a *stale* position until the
  /// fix had moved 15 m, which suppressed the send by making the payload
  /// identical. A new ping defeats that dedupe by itself, so the packet went
  /// out anyway carrying a puck up to 15 m behind the ping beside it. Adam saw
  /// it on a walk: "the pings appear ahead of the current location and center".
  group('movement gate', () {
    late WatchBridgeService bridge;
    late MethodChannel channel;
    late List<Map<Object?, Object?>> sent;

    /// Waiting out the 2 s non-urgent throttle is only necessary when the
    /// assertion is that nothing was sent. A fixed wait tuned near that
    /// boundary flakes on a loaded machine — this suite has already seen it —
    /// so the positive cases poll instead and only "no send" pays a fixed cost.
    const suppressionWindow = Duration(seconds: 3);
    const sendTimeout = Duration(seconds: 8);

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      channel = const MethodChannel('meshmapper/watch_move_test');
      bridge = WatchBridgeService(channel: channel);
      sent = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'status') {
          return {
            'supported': true,
            'activated': true,
            'paired': true,
            'installed': true,
            'reachable': true,
          };
        }
        if (call.method == 'sync') {
          final args = call.arguments as Map<Object?, Object?>;
          sent.add(args['payload'] as Map<Object?, Object?>);
          return true;
        }
        return null;
      });
      bridge.attachCommandHandler((_) => null);
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      bridge.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    WatchGeo geoAt(
      double lat, {
      required int fixedAtMs,
      List<WatchPing> pings = const [],
    }) =>
        WatchGeo(
          you: WatchPosition(
            lat: lat,
            lon: -122.3,
            fixedAt: DateTime.fromMillisecondsSinceEpoch(fixedAtMs),
          ),
          pings: pings,
          repeaters: const [],
          heard: const [],
          linkedRepeaterIds: const [],
        );

    void schedule(WatchGeo geo) {
      final snapshot = _snapshot(geo: geo);
      bridge.schedule(
        () => snapshot,
        urgencyKeyBuilder: () => snapshot.urgencyKey,
        immediate: true,
      );
    }

    /// Polls for the send rather than sleeping a fixed interval. The bridge
    /// reschedules instead of sending while the throttle is closed, so the
    /// delay is real but its exact length is not the thing under test.
    Future<void> pushExpectingSend(WatchGeo geo, int total) async {
      schedule(geo);
      final deadline = DateTime.now().add(sendTimeout);
      while (sent.length < total && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
      expect(sent, hasLength(total));
    }

    /// There is nothing to poll for, so this waits past the throttle *and* the
    /// retry it schedules: "no send" has to mean suppressed, not deferred.
    Future<void> pushExpectingSuppression(WatchGeo geo, int total) async {
      schedule(geo);
      await Future<void>.delayed(suppressionWindow);
      expect(sent, hasLength(total));
    }

    double sentLat(int index) {
      final geo = sent[index]['geo'] as Map<Object?, Object?>;
      final you = geo['you'] as Map<Object?, Object?>;
      return you['lat'] as double;
    }

    test('suppresses jitter, but never a payload that is going out anyway',
        () async {
      // 1e-5 degrees of latitude is about 1.11 m here, so 47.60002 is roughly
      // 2 m from the baseline and 47.6003 is roughly 33 m.
      await pushExpectingSend(geoAt(47.6, fixedAtMs: 1760000000000), 1);

      // A newer fix time and a couple of metres. This is a stationary phone,
      // and it must not reach the radio — including on the retry the throttle
      // scheduled, which `settle` has already allowed to fire.
      await pushExpectingSuppression(geoAt(47.60002, fixedAtMs: 1760000030000), 1);

      // The same two metres, now travelling with a ping. The ping alone
      // defeats the dedupe, so this send happens either way; the assertion is
      // that it carries the *current* fix rather than the last one sent.
      await pushExpectingSend(
        geoAt(
          47.60002,
          fixedAtMs: 1760000060000,
          pings: [
            WatchPing(
              id: 'rx-1760000060000',
              lat: 47.60002,
              lon: -122.3,
              kind: 'rx',
              color: const WatchColor(0, 0, 255),
              at: DateTime.fromMillisecondsSinceEpoch(1760000060000),
            ),
          ],
        ),
        2,
      );
      expect(sentLat(1), 47.60002,
          reason: 'the puck must not lag the ping beside it');

      // And the gate still opens on its own once the wearer has actually
      // moved, with nothing else in the payload changing.
      await pushExpectingSend(geoAt(47.6003, fixedAtMs: 1760000090000), 3);
      expect(sentLat(2), 47.6003);
    });

    /// The gate can only recognise a change confined to the fix itself, which
    /// is why `AppStateProvider._resolveRankingPosition` still holds a lagging
    /// position behind every *derived* field. `WatchHeardNode.distanceM` is a
    /// full-precision double, so feeding it the live fix would move the payload
    /// on every GPS jitter and walk straight past this gate — one send per
    /// throttle interval, from a phone sitting on a table.
    test('cannot see through a derived field, so derived fields must not move',
        () async {
      WatchGeo geoWith(double lat, double distanceM) => WatchGeo(
            you: WatchPosition(
              lat: lat,
              lon: -122.3,
              fixedAt: DateTime.fromMillisecondsSinceEpoch(1760000000000),
            ),
            pings: const [],
            repeaters: const [],
            heard: [
              WatchHeardNode(
                id: '4E5D',
                typeColor: const WatchColor(0, 1, 0),
                at: DateTime.fromMillisecondsSinceEpoch(1760000000000),
                distanceM: distanceM,
              ),
            ],
            linkedRepeaterIds: const [],
          );

      await pushExpectingSend(geoWith(47.6, 1423.5), 1);

      // Two metres of jitter, with the distance readout recomputed from it.
      await pushExpectingSend(geoWith(47.60002, 1421.3), 2);
    });

    test('measures from the last fix the watch received', () async {
      await pushExpectingSend(geoAt(47.6, fixedAtMs: 1760000000000), 1);

      // Two ~11 m steps in the same direction. Each is short of the threshold
      // on its own, but the second lands ~22 m from the fix the watch actually
      // holds, so it goes. Anchoring on the previous *computed* fix instead
      // would suppress a wearer walking away one short step at a time.
      await pushExpectingSuppression(geoAt(47.6001, fixedAtMs: 1760000030000), 1);
      await pushExpectingSend(geoAt(47.6002, fixedAtMs: 1760000060000), 2);
      expect(sentLat(1), 47.6002);
    });
  });
}
