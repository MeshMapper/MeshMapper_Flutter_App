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
  DateTime? updatedAt,
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
      updatedAt:
          updatedAt ?? DateTime.fromMillisecondsSinceEpoch(1759999999000),
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

    test('geo wire objects pin the key names the watch decodes', () {
      // Every one of these is non-optional on the Swift side, so a rename here
      // does not degrade — it fails `WatchSnapshot`'s throwing decode and the
      // watch stops receiving anything at all. Renaming `fixedAtMs` otherwise
      // passes this entire suite.
      final position = WatchPosition(
        lat: 47.6,
        lon: -122.3,
        headingDeg: 90,
        accuracyM: 5,
        fixedAt: DateTime.utc(2026, 8, 12),
      );
      expect(position.toMap().keys.toSet(), {
        'lat',
        'lon',
        'headingDeg',
        'accuracyM',
        'fixedAtMs',
      });

      final ping = WatchPing(
        id: 'tx-1',
        lat: 47.6,
        lon: -122.3,
        kind: 'tx',
        color: const WatchColor(1, 0, 0),
        at: DateTime.utc(2026, 8, 12),
      );
      expect(ping.toMap().keys.toSet(), {
        'id',
        'lat',
        'lon',
        'kind',
        'color',
        'atMs',
      });

      final heard = WatchHeardNode(
        id: '4E5D',
        name: 'Capitol Hill',
        snr: 7.5,
        at: DateTime.utc(2026, 8, 12),
        distanceM: 1200,
        snrColor: const WatchColor(0, 1, 0),
        typeColor: const WatchColor(0, 0, 1),
      );
      expect(heard.toMap().keys.toSet(), {
        'id',
        'name',
        'snr',
        'atMs',
        'distanceM',
        'snrColor',
        'typeColor',
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

    test('a cue stays presentable until the watch would drop it', () {
      // The bound the phone attaches by and the bound the watch presents by
      // are one rule. `WatchSessionClient.staleAfter` greys the surface and
      // drops the cue at 90 s; a phone that stopped attaching earlier would
      // recreate the silent-failure bug, because the wearer's wrist is down
      // for most of that window.
      final issuedAt = DateTime.utc(2026, 8, 12, 10);
      final cue = WatchHapticCue(
        id: 'failure-1',
        kind: 'failure',
        issuedAt: issuedAt,
        message: 'Could not start',
      );

      expect(cue.isPresentableAt(issuedAt), isTrue);
      expect(
        cue.isPresentableAt(issuedAt.add(const Duration(seconds: 89))),
        isTrue,
        reason: 'a wearer who raises their wrist late still gets the reason',
      );
      expect(
        cue.isPresentableAt(issuedAt.add(WatchWire.cueReadableFor)),
        isFalse,
        reason: 'past the stale boundary the watch drops it anyway',
      );
    });

    test('the cue survives the snapshot that carried it', () {
      // The defect this pins: the phone treated native accepting one payload
      // as the wearer having seen the cue, cleared it, and — because the cue
      // ID is in the urgency key — immediately sent an urgent, cue-less
      // payload that overwrote the retained application context. A suspended
      // watch woke to idle UI and no account of the failure.
      //
      // Both snapshots must carry the cue, and both must agree it is urgent,
      // or the cheap preflight key and the built payload drift.
      final issuedAt = DateTime.utc(2026, 8, 12, 10);
      final cue = WatchHapticCue(
        id: 'failure-1',
        kind: 'failure',
        issuedAt: issuedAt,
        message: 'Could not start',
      );

      final first = _snapshot(cue: cue);
      final second = _snapshot(
        cue: cue,
        updatedAt: issuedAt.add(const Duration(seconds: 30)),
      );

      expect(second.toMap()['cue'], first.toMap()['cue']);
      expect(second.urgencyKey, first.urgencyKey,
          reason: 'a re-attached cue is not a new event to flush for');
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
      bool floodTrafficEnabled = true,
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
          floodTrafficEnabled: floodTrafficEnabled,
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

    test('a queued Stop cannot end a session it never saw', () {
      // Stop is exempt from the transmit-age window, so it can arrive
      // arbitrarily late — the phone out of range, the watch suspended mid
      // transfer. That exemption assumed one session was as good as another.
      // A Stop queued against A, delivered after A ended and B began, used to
      // stop B silently, and the wearer found out by noticing that recording
      // had halted.
      final wrongSession = resolveWatchSessionCommandAdmission(
        kind: WatchCommandKind.stopSession,
        isSessionActive: true,
        isSessionStarting: false,
        requestedSessionId: 'session-a',
        currentSessionId: 'session-b',
      );
      expect(wrongSession.shouldRun, isFalse);
      expect(wrongSession.refusal, 'That session already ended');

      final sameSession = resolveWatchSessionCommandAdmission(
        kind: WatchCommandKind.stopSession,
        isSessionActive: true,
        isSessionStarting: false,
        requestedSessionId: 'session-a',
        currentSessionId: 'session-a',
      );
      expect(sameSession, (shouldRun: true, refusal: null));

      // An older watch build names no session. It is admitted exactly as it
      // was before the field existed, because refusing it would strand a
      // wearer whose only Stop button the phone had stopped honouring.
      final olderBuild = resolveWatchSessionCommandAdmission(
        kind: WatchCommandKind.stopSession,
        isSessionActive: true,
        isSessionStarting: false,
        currentSessionId: 'session-b',
      );
      expect(olderBuild, (shouldRun: true, refusal: null));
    });

    test('a Stop with nothing running stays a harmless no-op', () {
      // Checked after the active-session gate on purpose. With no session, a
      // mismatched id must not turn a silent no-op into a refusal for
      // something that is already over — the wearer asked for stopped, and
      // stopped is what they have.
      final stop = resolveWatchSessionCommandAdmission(
        kind: WatchCommandKind.stopSession,
        isSessionActive: false,
        isSessionStarting: false,
        requestedSessionId: 'session-a',
        currentSessionId: 'idle',
      );

      expect(stop, (shouldRun: false, refusal: null));
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

    test('diagnostics stay reachable exactly when they are needed', () {
      bool show({
        bool isSupportedPlatform = true,
        bool supported = true,
        bool paired = false,
        bool activated = true,
        bool hasEverPaired = false,
      }) =>
          resolveShouldShowWatchDiagnostics(
            isSupportedPlatform: isSupportedPlatform,
            supported: supported,
            paired: paired,
            activated: activated,
            hasEverPaired: hasEverPaired,
          );

      // The case the old rule got backwards: activation failed, so `paired`
      // reads false for a phone that may well have a watch — and the screen
      // that would explain the failure was the thing being hidden.
      expect(show(activated: false), isTrue,
          reason: 'a session that never came up cannot deny a watch exists');

      // A healthy session that genuinely sees no watch. The common iPhone.
      expect(show(), isFalse);

      // Seen now, or seen once. Pairing history stays one-way on purpose: an
      // unpaired watch is when this is most useful.
      expect(show(paired: true), isTrue);
      expect(show(hasEverPaired: true), isTrue);

      // Not an iOS host at all, and a host without WatchConnectivity.
      expect(show(isSupportedPlatform: false, activated: false), isFalse);
      expect(show(supported: false, activated: false), isFalse,
          reason: 'no WatchConnectivity means no watch to diagnose');
    });

    test('the wrist is never offered a mode every start would refuse', () {
      // Hybrid used to be advertised whenever the phone was connected and TX
      // was allowed, ignoring Offline Mode — where sessionStartAvailability
      // refuses every start with 'Offline Mode'. That is a permanently dead
      // button on a screen with room for two.
      expect(
        resolveAvailableWatchStartModes(
          isConnected: true,
          txAllowed: true,
          offlineMode: true,
          floodTrafficEnabled: true,
        ),
        [WatchStartMode.passive],
      );

      expect(
        resolveAvailableWatchStartModes(
          isConnected: true,
          txAllowed: true,
          offlineMode: false,
          floodTrafficEnabled: true,
        ),
        [WatchStartMode.passive, WatchStartMode.hybrid],
      );

      // Passive is always offered: it is what the wrist falls back to, and the
      // phone still re-validates the start.
      for (final connected in [true, false]) {
        for (final tx in [true, false]) {
          expect(
            resolveAvailableWatchStartModes(
              isConnected: connected,
              txAllowed: tx,
              offlineMode: false,
              floodTrafficEnabled: true,
            ),
            contains(WatchStartMode.passive),
          );
        }
      }
    });

    test('flood traffic off withdraws Hybrid from the wrist', () {
      // The phone builds Send Ping and the Active/Hybrid button inside
      // `if (!txNotAllowed && floodTrafficVisible)`, so with flood off neither
      // control exists. The preference defaults off and a regional
      // `flood_disabled` veto forces it off, so a wrist that ignored this was
      // advertising a phone-withheld control in the *default* configuration —
      // and in the veto case one a zone admin forbade.
      expect(
        resolveAvailableWatchStartModes(
          isConnected: true,
          txAllowed: true,
          offlineMode: false,
          floodTrafficEnabled: false,
        ),
        [WatchStartMode.passive],
        reason: 'Passive is not flood traffic and stays offered',
      );
    });

    test('an advertised Hybrid is one the start gate actually admits', () {
      // The pairing the two resolvers must agree on: whenever Hybrid is
      // offered, a start in that mode is not refused for a configuration
      // reason. Transient timing guards are deliberately not checked here.
      for (final offline in [true, false]) {
        for (final flood in [true, false]) {
          final offered = resolveAvailableWatchStartModes(
            isConnected: true,
            txAllowed: true,
            offlineMode: offline,
            floodTrafficEnabled: flood,
          ).contains(WatchStartMode.hybrid);

          final admitted = startAvailability(
            isTransmitMode: true,
            txBlockedByOffline: offline,
            floodTrafficEnabled: flood,
          );

          expect(offered, admitted.allowed,
              reason: 'offered and admitted must not drift on '
                  'offline=$offline flood=$flood');
        }
      }
    });

    test('flood traffic gates transmit starts but never Passive', () {
      final hybrid =
          startAvailability(isTransmitMode: true, floodTrafficEnabled: false);
      expect(hybrid.allowed, isFalse);
      expect(hybrid.reason, 'Flood Traffic Off');

      // Passive monitoring is not flood traffic. The phone's Passive button
      // sits outside the flood gate, so the wrist's must too — withdrawing it
      // would strand a wearer with no way to start anything at all.
      expect(
        startAvailability(isTransmitMode: false, floodTrafficEnabled: false)
            .allowed,
        isTrue,
      );
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

    test('Passive ignores the policy blockers that only constrain a TX start',
        () {
      final passive = startAvailability(
        isTransmitMode: false,
        txBlockedByOffline: true,
        txNotAllowed: true,
        transmitValidationReason: 'Waiting for GPS lock',
      );

      expect(passive, (allowed: true, reason: null));
    });

    test('Passive still waits out a manual ping, because Passive transmits',
        () {
      // Passive Mode starts by sending a discovery request and repeats it every
      // 30 s. Letting the wrist start one inside a manual ping's TX window puts
      // a second transmit on air where the phone's own Passive button is dead.
      final blocked = <String, SessionStartAvailability>{
        'Cooling down':
            startAvailability(isTransmitMode: false, cooldownActive: true),
        'Ping in progress':
            startAvailability(isTransmitMode: false, isPingSending: true),
        'Listening for ping response':
            startAvailability(isTransmitMode: false, rxWindowActive: true),
      };

      for (final entry in blocked.entries) {
        expect(entry.value.allowed, isFalse, reason: entry.key);
        expect(entry.value.reason, entry.key);
      }
    });
  });

  group('bridge command handling', () {
    late WatchBridgeService bridge;
    late MethodChannel channel;
    late List<WatchCommandKind> handled;
    late bool nativeAvailable;
    late bool syncSucceeds;
    late int syncCalls;
    late int clearCalls;

    /// Short enough that a suite does not spend its life asleep, long enough
    /// that a loaded machine cannot cross it between two adjacent statements.
    /// The behaviour under test is the ordering the throttle imposes, never the
    /// length of the wire's own 2 s interval.
    const throttle = Duration(milliseconds: 80);

    /// Comfortably past [throttle], including the retry it schedules.
    const settle = Duration(milliseconds: 200);

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      channel = const MethodChannel('meshmapper/watch_test');
      bridge = WatchBridgeService(
        channel: channel,
        minimumNonUrgentInterval: throttle,
        mapGeoClaimFreshFor: const Duration(milliseconds: 250),
      );
      handled = [];
      nativeAvailable = true;
      syncSucceeds = true;
      syncCalls = 0;
      clearCalls = 0;
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
        if (call.method == 'clear') {
          clearCalls++;
          return null;
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
      double? clockOffsetMs,
      bool? forceRefresh,
      String? sessionId,
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
            if (clockOffsetMs != null) 'clockOffsetMs': clockOffsetMs,
            if (forceRefresh != null) 'forceRefresh': forceRefresh,
            if (sessionId != null) 'sessionId': sessionId,
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
            'nativeCacheCleared': true,
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

    test('a reachability flip alone leaves the caches intact', () async {
      // `sessionReachabilityDidChange` fires on every wrist raise and lower,
      // and native does not drop `lastContextData` there. Treating it as cache
      // invalidation made each glance force a full `updateApplicationContext`
      // resend and silently voided the map-geo lease.
      bridge.attachCommandHandler((_) => null);
      await Future<void>.delayed(Duration.zero);

      void schedule() => bridge.schedule(
            _snapshot,
            urgencyKeyBuilder: () => _snapshot().urgencyKey,
            immediate: true,
          );

      schedule();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(syncCalls, 1);

      for (final reachable in [false, true]) {
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
          channel.name,
          channel.codec.encodeMethodCall(MethodCall(
            'availabilityChanged',
            {
              'supported': true,
              'activated': true,
              'paired': true,
              'installed': true,
              'reachable': reachable,
              'nativeCacheCleared': false,
            },
          )),
          null,
        );
        schedule();
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }

      expect(syncCalls, 1,
          reason: 'an unchanged payload must stay deduplicated across glances');
    });

    // The watch asks for a snapshot after a relaunch, holding a retained
    // context it now ages honestly. The phone forgets its delivered fingerprint
    // only on a WatchConnectivity state change, and a watch app restart is not
    // one — pairing and installation never changed. Without a force path an
    // unchanged session answers that request with silence, and the wearer keeps
    // looking at state marked stale while the phone is alive and listening.
    group('a requested refresh defeats dedupe', () {
      // `settle` clears the non-urgent radio interval. A forced refresh is
      // deliberately still subject to it, so anything shorter would only prove
      // the throttle deferred the flush, not what the flush decided.
      Future<void> deliver({
        DateTime? updatedAt,
        bool forceDelivery = false,
        Duration wait = settle,
      }) async {
        bridge.schedule(
          () => _snapshot(updatedAt: updatedAt),
          urgencyKeyBuilder: () => _snapshot(updatedAt: updatedAt).urgencyKey,
          immediate: true,
          forceDelivery: forceDelivery,
        );
        await Future<void>.delayed(wait);
      }

      test('an identical payload is still deduplicated without one', () async {
        bridge.attachCommandHandler((_) => null);
        await Future<void>.delayed(Duration.zero);

        await deliver();
        expect(syncCalls, 1);

        await deliver(
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1760000600000),
        );

        expect(syncCalls, 1,
            reason: 'a newer updatedAt alone must not spend the radio');
      });

      test('a forced refresh sends the unchanged payload again', () async {
        bridge.attachCommandHandler((_) => null);
        await Future<void>.delayed(Duration.zero);

        await deliver();
        expect(syncCalls, 1);

        // Semantically identical to what the watch already holds. Only
        // updatedAt moved, which is exactly what proves the phone is alive.
        await deliver(
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1760000600000),
          forceDelivery: true,
        );

        expect(syncCalls, 2,
            reason: 'a refresh the watch asked for must reach it');
      });

      test('the throttle delays a forced refresh but cannot cancel it',
          () async {
        bridge.attachCommandHandler((_) => null);
        await Future<void>.delayed(Duration.zero);

        // The first delivery is unthrottled — nothing has been built yet — so
        // the forced one has to follow it closely enough to land inside the
        // interval it opens.
        await deliver(wait: const Duration(milliseconds: 10));
        expect(syncCalls, 1);

        await deliver(
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1760000600000),
          forceDelivery: true,
          wait: const Duration(milliseconds: 10),
        );

        expect(syncCalls, 1,
            reason: 'the radio interval still governs when it goes out');

        await Future<void>.delayed(settle);

        expect(syncCalls, 2,
            reason: 'the obligation must survive its own deferral');
      });

      test('a native refusal does not consume the obligation', () async {
        bridge.attachCommandHandler((_) => null);
        await Future<void>.delayed(Duration.zero);

        await deliver();
        expect(syncCalls, 1);

        // Native refuses. The fingerprint is deliberately not updated, so an
        // obligation dropped here would dedupe against that same payload on
        // every later flush and strand the watch exactly as before the fix.
        syncSucceeds = false;
        await deliver(
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1760000600000),
          forceDelivery: true,
        );
        expect(syncCalls, 2,
            reason: 'the refused attempt still reached native');

        syncSucceeds = true;
        // Note the absent forceDelivery: the obligation has to be the thing
        // carrying this through, not a fresh request.
        await deliver(
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1760000700000),
        );

        expect(syncCalls, 3,
            reason: 'a refusal must leave the refresh still owed');
      });

      test('the obligation is spent, not standing', () async {
        bridge.attachCommandHandler((_) => null);
        await Future<void>.delayed(Duration.zero);

        await deliver();
        await deliver(
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1760000600000),
          forceDelivery: true,
        );
        expect(syncCalls, 2);

        await deliver(
          updatedAt: DateTime.fromMillisecondsSinceEpoch(1760000700000),
        );

        expect(syncCalls, 2,
            reason: 'one request buys one delivery, not a permanent bypass');
      });
    });

    group('a session that ends clears the watch', () {
      // The disconnect path: the provider stops producing a snapshot, and the
      // bridge must tell native to drop its retained application context so the
      // wrist is not left rendering a session that no longer exists.
      //
      // Untested before the throttle became injectable, because reaching the
      // clear meant waiting out the real interval twice.
      test('a null snapshot clears native and does not clear twice', () async {
        bridge.attachCommandHandler((_) => null);
        await Future<void>.delayed(Duration.zero);

        WatchSnapshot? pending = _snapshot();
        void schedule() => bridge.schedule(
              () => pending,
              urgencyKeyBuilder: () => _snapshot().urgencyKey,
              immediate: true,
            );

        schedule();
        await Future<void>.delayed(settle);
        expect(syncCalls, 1);
        expect(clearCalls, 0);

        pending = null;
        schedule();
        await Future<void>.delayed(settle);

        expect(clearCalls, 1,
            reason: 'native must forget the context when the session ends');

        // Still nothing to send, and native has already been reconciled.
        schedule();
        await Future<void>.delayed(settle);

        expect(clearCalls, 1,
            reason: 'an already-cleared bridge must not keep clearing');
      });

      test('a snapshot after a clear is delivered, not deduped away', () async {
        bridge.attachCommandHandler((_) => null);
        await Future<void>.delayed(Duration.zero);

        WatchSnapshot? pending = _snapshot();
        void schedule() => bridge.schedule(
              () => pending,
              urgencyKeyBuilder: () => _snapshot().urgencyKey,
              immediate: true,
            );

        schedule();
        await Future<void>.delayed(settle);
        expect(syncCalls, 1);

        pending = null;
        schedule();
        await Future<void>.delayed(settle);
        expect(clearCalls, 1);

        // The same payload as the first send. The clear dropped the
        // fingerprint, so this is new information to a watch holding nothing.
        pending = _snapshot();
        schedule();
        await Future<void>.delayed(settle);

        expect(syncCalls, 2,
            reason: 'a cleared watch must not be deduped against stale state');
      });
    });

    test('a burst of notifications coalesces into one build', () async {
      // The 200 ms debounce, which nothing covered. It is the first of the five
      // suppression gates and the only one that acts on scheduling rather than
      // on content, so a regression here would be invisible to every other test
      // in this file.
      final debounced = WatchBridgeService(
        channel: channel,
        debounceDelay: const Duration(milliseconds: 60),
        minimumNonUrgentInterval: throttle,
      );
      addTearDown(debounced.dispose);
      debounced.attachCommandHandler((_) => null);
      await Future<void>.delayed(Duration.zero);

      var builds = 0;
      for (var i = 0; i < 8; i++) {
        debounced.schedule(
          () {
            builds++;
            return _snapshot();
          },
          urgencyKeyBuilder: () => _snapshot().urgencyKey,
        );
      }

      expect(builds, 0, reason: 'nothing is built while the burst is arriving');

      await Future<void>.delayed(const Duration(milliseconds: 200));

      expect(builds, 1,
          reason: 'eight notifications must cost one snapshot, not eight');
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

    test('an accepted native send is recorded, not called delivered', () async {
      // There is deliberately no per-snapshot delivery callback here. Native
      // returning true means `updateApplicationContext` accepted the blob; the
      // watch may be suspended and ingest it much later, or never. Anything
      // that treated this as wearer-visible delivery — the cue lifetime once
      // did — dropped state the watch had not yet seen.
      bridge.attachCommandHandler((_) => null);
      await Future<void>.delayed(Duration.zero);
      final snapshot = _snapshot();

      bridge.schedule(
        () => snapshot,
        urgencyKeyBuilder: () => snapshot.urgencyKey,
        immediate: true,
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));

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

    test('an unrenewed suppression lease expires back to full geography',
        () async {
      // Suppression is a lease, not a latch. The watch renews it every five
      // minutes while its map stays hidden; if those renewals stop — the watch
      // app dies, the command is lost — the phone has to fail safe toward
      // sending too much rather than leaving a future map blank.
      //
      // Untestable before the interval became injectable: the real lease is ten
      // minutes long.
      bridge.attachCommandHandler((_) => null);

      await sendCommand(
        'lease-off',
        'requestSnapshot',
        mapGeoNeeded: false,
        issuedAtMs: DateTime.now().millisecondsSinceEpoch.toDouble(),
      );
      expect(bridge.shouldIncludeMapGeo, isFalse,
          reason: 'a fresh claim suppresses the expensive payload');

      await Future<void>.delayed(const Duration(milliseconds: 320));

      expect(bridge.shouldIncludeMapGeo, isTrue,
          reason: 'an unrenewed lease must expire, not persist');
    });

    test('a renewal keeps the lease alive without the wearer asking', () async {
      bridge.attachCommandHandler((_) => null);

      await sendCommand(
        'lease-1',
        'requestSnapshot',
        mapGeoNeeded: false,
        issuedAtMs: DateTime.now().millisecondsSinceEpoch.toDouble(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      // The renewal the watch sends every five minutes on the real wire.
      await sendCommand(
        'lease-2',
        'requestSnapshot',
        mapGeoNeeded: false,
        issuedAtMs: DateTime.now().millisecondsSinceEpoch.toDouble(),
      );
      await Future<void>.delayed(const Duration(milliseconds: 150));

      expect(bridge.shouldIncludeMapGeo, isFalse,
          reason: 'renewal must reset the lease, or a hidden map still pays');
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

    test('a redelivered acceptance still acks as accepted', () async {
      // The other half of the echo: an accepted command must not start
      // reporting itself refused just because the conditions moved on.
      var refuse = false;
      bridge.attachCommandHandler((command) async {
        handled.add(command.kind);
        return refuse ? 'Not connected' : null;
      });

      final issuedAtMs = DateTime.now().millisecondsSinceEpoch.toDouble();
      final first = await sendCommand(
        'queued-3',
        'manualPing',
        issuedAtMs: issuedAtMs,
      );
      expect(first?['accepted'], isTrue);

      refuse = true;
      final redelivered = await sendCommand(
        'queued-3',
        'manualPing',
        issuedAtMs: issuedAtMs,
      );

      expect(handled, hasLength(1));
      expect(redelivered?['accepted'], isTrue);
      expect(redelivered?['reason'], isNull);
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

    test('a refused queued command is never retried once conditions change',
        () async {
      // The counterpart to the test above, and the branch that matters on a
      // shipping watch: transferUserInfo has no reply to act on a refusal, so
      // WatchConnectivity redelivers the same tap on its own schedule.
      // Forgetting the ID the way the legacy reply path does would let a stale
      // wrist action transmit the moment the phone became willing.
      var refuse = true;
      final issuedAtMs = DateTime.now().millisecondsSinceEpoch.toDouble();
      bridge.attachCommandHandler((command) async {
        handled.add(command.kind);
        return refuse ? 'Not connected' : null;
      });

      final first = await sendCommand(
        'queued-2',
        'startSession',
        issuedAtMs: issuedAtMs,
      );
      expect(first?['accepted'], isFalse);
      expect(first?['reason'], 'Not connected');

      refuse = false;
      final redelivered = await sendCommand(
        'queued-2',
        'startSession',
        issuedAtMs: issuedAtMs,
      );

      expect(handled, hasLength(1),
          reason: 'redelivery must never turn yesterday\'s tap into a '
              'transmit');
      expect(redelivered?['accepted'], isFalse,
          reason: 'the ack must describe what happened, not what was hoped');
      expect(redelivered?['reason'], 'Not connected',
          reason: 'the recorded outcome is echoed, not recomputed');
    });

    // transferUserInfo keeps a tapped command alive until the phone is
    // reachable again, so the admission window is the only thing stopping a
    // queued transmit from firing long after the wearer asked for it. Both
    // bounds are load-bearing: "too old" is the queue sitting on it, and "too
    // far in the future" is a skewed watch clock buying the same command extra
    // life. requestSnapshot is deliberately exempt — it transmits nothing.
    group('queued command age', () {
      // Stop is absent on purpose: it takes the radio off air, so a late one
      // is always the safe direction and is exempt below.
      const transmitting = ['startSession', 'manualPing'];

      double nowMs() => DateTime.now().millisecondsSinceEpoch.toDouble();

      for (final kind in transmitting) {
        test('$kind older than 30 seconds is refused', () async {
          final refusals = <String>[];
          bridge.attachCommandHandler(
            (command) async {
              handled.add(command.kind);
              return null;
            },
            onRefusal: refusals.add,
          );

          final reply = await sendCommand(
            'aged-$kind',
            kind,
            issuedAtMs: nowMs() - const Duration(seconds: 31).inMilliseconds,
          );

          expect(reply?['accepted'], isFalse);
          expect(reply?['reason'], 'Took too long to reach iPhone');
          expect(handled, isEmpty,
              reason: 'an expired command must never reach admission');
          expect(refusals, ['Took too long to reach iPhone'],
              reason: 'the wearer is told why the tap did nothing');
        });

        test('$kind dated far into the future is refused', () async {
          bridge.attachCommandHandler((command) async {
            handled.add(command.kind);
            return null;
          });

          final reply = await sendCommand(
            'future-$kind',
            kind,
            issuedAtMs: nowMs() + const Duration(minutes: 10).inMilliseconds,
          );

          expect(reply?['accepted'], isFalse,
              reason: 'a fast watch clock must not extend the 30s window');
          expect(handled, isEmpty);
        });

        test('$kind within the clock tolerance is accepted', () async {
          bridge.attachCommandHandler((command) async {
            handled.add(command.kind);
            return null;
          });

          final reply = await sendCommand(
            'skewed-$kind',
            kind,
            issuedAtMs: nowMs() + const Duration(seconds: 2).inMilliseconds,
          );

          expect(reply?['accepted'], isTrue,
              reason: 'ordinary skew must not refuse a live tap');
          expect(handled, hasLength(1));
        });
      }

      test('an untimestamped command is still accepted', () async {
        bridge.attachCommandHandler((command) async {
          handled.add(command.kind);
          return null;
        });

        final reply = await sendCommand('legacy-1', 'manualPing');

        expect(reply?['accepted'], isTrue,
            reason: 'older watch builds send no issuedAtMs');
        expect(handled, hasLength(1));
      });

      test('a skewed watch clock degrades, it does not refuse everything',
          () async {
        // The failure this replaces: two devices that disagree about the time
        // by more than the tolerance had every timestamped command refused, for
        // as long as the skew lasted. An unshared clock is a normal condition,
        // not a reason to make the wrist inert.
        bridge.attachCommandHandler((command) async {
          handled.add(command.kind);
          return null;
        });

        // A watch running four minutes fast. Without the offset this stamp is
        // 240 s in the future and fails the lower bound outright.
        const skew = Duration(minutes: 4);
        final reply = await sendCommand(
          'skewed-fast',
          'manualPing',
          issuedAtMs: nowMs() +
              skew.inMilliseconds -
              const Duration(seconds: 2).inMilliseconds,
          clockOffsetMs: -skew.inMilliseconds.toDouble(),
        );

        expect(reply?['accepted'], isTrue,
            reason: 'a measured offset must make the age a real elapsed time');
        expect(handled, [WatchCommandKind.manualPing]);
      });

      test('the offset corrects the age, it does not excuse a stale command',
          () async {
        // The window still has to mean something: a genuinely old command is
        // still old once the clocks agree, and correcting for skew must not
        // become a way to smuggle yesterday's tap onto the radio.
        final refusals = <String>[];
        bridge.attachCommandHandler(
          (command) async {
            handled.add(command.kind);
            return null;
          },
          onRefusal: refusals.add,
        );

        const skew = Duration(minutes: 4);
        final reply = await sendCommand(
          'skewed-and-stale',
          'manualPing',
          issuedAtMs: nowMs() +
              skew.inMilliseconds -
              const Duration(seconds: 45).inMilliseconds,
          clockOffsetMs: -skew.inMilliseconds.toDouble(),
        );

        expect(reply?['accepted'], isFalse);
        expect(reply?['reason'], 'Took too long to reach iPhone');
        expect(handled, isEmpty);
        expect(refusals, ['Took too long to reach iPhone']);
      });

      test('an older watch build sending no offset behaves exactly as before',
          () async {
        bridge.attachCommandHandler((command) async {
          handled.add(command.kind);
          return null;
        });

        final fresh = await sendCommand(
          'no-offset-fresh',
          'manualPing',
          issuedAtMs: nowMs() - const Duration(seconds: 5).inMilliseconds,
        );
        expect(fresh?['accepted'], isTrue);

        final stale = await sendCommand(
          'no-offset-stale',
          'manualPing',
          issuedAtMs: nowMs() - const Duration(seconds: 31).inMilliseconds,
        );
        expect(stale?['accepted'], isFalse,
            reason: 'absent offset must mean zero, not unbounded tolerance');
      });

      test('an aged requestSnapshot is exempt from the transmit window',
          () async {
        bridge.attachCommandHandler((command) async {
          handled.add(command.kind);
          return null;
        });

        final reply = await sendCommand(
          'aged-snapshot',
          'requestSnapshot',
          issuedAtMs: nowMs() - const Duration(minutes: 5).inMilliseconds,
        );

        expect(reply?['accepted'], isTrue,
            reason: 'asking for state transmits nothing and cannot go stale');
        expect(handled, [WatchCommandKind.requestSnapshot]);
      });

      test('an aged stopSession is exempt, because stopping is the safe way',
          () async {
        bridge.attachCommandHandler((command) async {
          handled.add(command.kind);
          return null;
        });

        final reply = await sendCommand(
          'aged-stop',
          'stopSession',
          issuedAtMs: nowMs() - const Duration(minutes: 5).inMilliseconds,
        );

        expect(reply?['accepted'], isTrue,
            reason: 'refusing a late stop leaves the radio transmitting');
        expect(handled, [WatchCommandKind.stopSession]);
      });

      test('a stopSession from a fast watch clock is exempt too', () async {
        bridge.attachCommandHandler((command) async {
          handled.add(command.kind);
          return null;
        });

        final reply = await sendCommand(
          'future-stop',
          'stopSession',
          issuedAtMs: nowMs() + const Duration(minutes: 10).inMilliseconds,
        );

        expect(reply?['accepted'], isTrue,
            reason: 'skew cannot make stopping unsafe; it can only delay it');
        expect(handled, [WatchCommandKind.stopSession]);
      });
    });

    // requestSnapshot carries two intents down one wire. Only a genuine plea
    // for state may defeat dedupe; the map-geo lease renews as the same command
    // every five minutes while the map stays hidden, and forcing those would
    // spend the radio exactly where the lease exists to save it. The intent is
    // stated rather than inferred from mapGeoNeeded, which the bridge may
    // resolve to null when a suppression claim is stale or out of order.
    group('refresh intent is explicit', () {
      late List<WatchCommand> received;

      setUp(() {
        received = <WatchCommand>[];
        bridge.attachCommandHandler((command) {
          received.add(command);
          return null;
        });
      });

      test('a stated refresh asks for delivery', () async {
        await sendCommand('r-1', 'requestSnapshot',
            mapGeoNeeded: true, forceRefresh: true);

        expect(received.single.forceRefresh, isTrue);
      });

      test('a lease renewal does not', () async {
        await sendCommand('r-2', 'requestSnapshot',
            mapGeoNeeded: false, forceRefresh: false);

        expect(received.single.forceRefresh, isFalse,
            reason: 'renewals repeat every five minutes and must stay cheap');
      });

      test('returning to the map does not force on its own', () async {
        // Restoring geography changes the payload by itself, so dedupe is
        // already defeated where it matters. Forcing here would only add a
        // guaranteed send to a page transition the wearer makes constantly.
        await sendCommand('r-3', 'requestSnapshot', mapGeoNeeded: true);

        expect(received.single.forceRefresh, isFalse);
      });

      test('an older watch build without the field never forces', () async {
        await sendCommand('r-4', 'requestSnapshot');

        expect(received.single.forceRefresh, isFalse,
            reason: 'absent must mean false, not "assume the expensive thing"');
      });
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

    test('a stop command carries its session id to admission', () async {
      // The bridge is the only place that names the wire key, and the watch
      // target has no Swift tests to pin the other end. If `sessionId` were
      // renamed here, every production stop would arrive unattributed and be
      // admitted against whatever session happened to be running — the exact
      // failure the field exists to prevent, reintroduced silently.
      WatchCommand? seen;
      bridge.attachCommandHandler((command) {
        seen = command;
        return null;
      });

      await sendCommand('stop-1', 'stopSession', sessionId: 'session-a');

      expect(seen?.kind, WatchCommandKind.stopSession);
      expect(seen?.sessionId, 'session-a');
    });

    test('a stop from an older watch build names no session', () async {
      WatchCommand? seen;
      bridge.attachCommandHandler((command) {
        seen = command;
        return null;
      });

      await sendCommand('stop-2', 'stopSession');

      expect(seen?.sessionId, isNull);
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

    /// The throttle is injected rather than waited out. What this group tests
    /// is which payloads the movement gate lets through, and that answer does
    /// not depend on the wire's interval being two seconds.
    const throttle = Duration(milliseconds: 80);

    /// Waiting out the throttle is only necessary when the assertion is that
    /// nothing was sent. A fixed wait tuned near that boundary flakes on a
    /// loaded machine — this suite has already seen it — so the positive cases
    /// poll instead and only "no send" pays a fixed cost.
    const suppressionWindow = Duration(milliseconds: 240);
    const sendTimeout = Duration(seconds: 8);

    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      channel = const MethodChannel('meshmapper/watch_move_test');
      bridge = WatchBridgeService(
        channel: channel,
        minimumNonUrgentInterval: throttle,
      );
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
      await pushExpectingSuppression(
          geoAt(47.60002, fixedAtMs: 1760000030000), 1);

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
      await pushExpectingSuppression(
          geoAt(47.6001, fixedAtMs: 1760000030000), 1);
      await pushExpectingSend(geoAt(47.6002, fixedAtMs: 1760000060000), 2);
      expect(sentLat(1), 47.6002);
    });
  });
}
