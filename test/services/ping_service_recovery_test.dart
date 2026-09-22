import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/models/device_model.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/countdown_timer_service.dart';
import 'package:mesh_mapper/services/gps_service.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/recent_coverage_service.dart';
import 'package:mesh_mapper/services/wakelock_service.dart';

/// A TX held back while a replacement API session is installed must leave the
/// auto lane armed.
///
/// Every interval timer here is one-shot, and the provider only releases the
/// recovery gate in a finally, so an Active or Hybrid tick that landed during
/// recovery used to end the lane for the rest of the session while the mode
/// flags still read enabled.

class _FakeGps implements GpsService {
  Position? position;
  int freshCalls = 0;

  /// Held open by the test to park a send on its fresh fix, the gap the
  /// second recovery bow-out lives in.
  Completer<void>? freshPositionGate;

  @override
  GpsStatus get status => GpsStatus.locked;

  @override
  Position? get lastPosition => position;

  @override
  bool get isAirborne => false;

  @override
  bool isAccuracyAcceptableForPing(Position position) => true;

  @override
  bool canPingAtPosition(Position position) => true;

  @override
  double get configuredMinDistance => 25.0;

  @override
  void markPingPosition(Position position) {}

  @override
  void markActivityPosition(Position position) {}

  @override
  Future<Position?> getFreshPosition(
      {Duration timeout = const Duration(seconds: 3)}) async {
    freshCalls++;
    final gate = freshPositionGate;
    if (gate != null) await gate.future;
    return position;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeConnection implements MeshCoreConnection {
  int txTransmits = 0;

  @override
  ConnectionStep get currentStep => ConnectionStep.connected;

  @override
  DeviceModel? get deviceModel => null;

  @override
  int? get lastNoiseFloor => null;

  @override
  int? get wardrivingChannelIndex => null;

  @override
  Uint8List? get wardrivingChannelKey => null;

  @override
  int? get wardrivingChannelHash => null;

  @override
  Stream<({Uint8List raw, double snr, int rssi})> get controlDataStream =>
      const Stream.empty();

  @override
  Stream<Uint8List> get traceDataStream => const Stream.empty();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #sendPing) {
      txTransmits++;
      return Future<void>.value();
    }
    throw UnimplementedError('MeshCoreConnection.${invocation.memberName}');
  }
}

class _FakeApiQueue implements ApiQueueService {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName.toString().contains('enqueue')) {
      return Future<void>.value();
    }
    throw UnimplementedError('ApiQueueService.${invocation.memberName}');
  }
}

class _FakeWakelock implements WakelockService {
  @override
  bool get isEnabled => false;

  @override
  Future<void> enable() async {}

  @override
  Future<void> disable() async {}

  @override
  Future<void> dispose() async {}
}

Position _pos({double lat = 45.0, double lon = -75.0}) => Position(
      latitude: lat,
      longitude: lon,
      timestamp: DateTime.now(),
      accuracy: 5.0,
      altitude: 0.0,
      altitudeAccuracy: 1.0,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 1.0,
    );

/// A coverage answer the test can change after the service is built.
class _Coverage {
  _Coverage(this.answer);
  RecentCoverage answer;
}

PingService _build(
  _FakeGps gps,
  _FakeConnection conn,
  _Coverage coverage,
  List<int> scheduled,
) {
  final service = PingService(
    gpsService: gps,
    connection: conn,
    apiQueue: _FakeApiQueue(),
    wakelockService: _FakeWakelock(),
    cooldownTimer: CooldownTimer(),
    manualPingCooldownTimer: ManualPingCooldownTimer(),
    rxWindowTimer: RxWindowTimer(),
    discoveryWindowTimer: DiscoveryWindowTimer(),
    deviceId: 'TEST',
  )..checkRecentCoverage = (lat, lon) => coverage.answer;
  service.getSessionId = () => 'YYZ-20260916-0001';
  service.getNextPingCounter = () => 1;
  service.onAutoPingScheduled = (intervalMs, skipReason) =>
      scheduled.add(intervalMs);
  return service;
}

void main() {
  testWidgets('a tick refused at the recovery gate re-arms the Active lane',
      (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final scheduled = <int>[];
    final ping = _build(gps, conn, _Coverage(RecentCoverage.clear), scheduled);

    // Recovery is installing a replacement session when Active mode starts, so
    // the opening ping is refused at the gate before the try.
    ping.setSessionRecoveryInProgress(true);
    await ping.enableAutoPing();
    await tester.pump();

    expect(conn.txTransmits, 0, reason: 'the gate held the ping back');
    expect(scheduled, isNotEmpty,
        reason: 'the refused tick must re-arm the one-shot interval timer');

    // The provider installs the new session and releases the gate. The lane
    // must still be counting: without the re-arm nothing fires here again.
    ping.setSessionRecoveryInProgress(false);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(conn.txTransmits, 1,
        reason: 'the lane survived the recovery and pinged on the next tick');

    ping.dispose();
  });

  testWidgets('recovery starting during the fresh fix unlocks and re-arms',
      (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final scheduled = <int>[];
    final ping = _build(gps, conn, _Coverage(RecentCoverage.clear), scheduled);

    // Park the opening ping on its fresh fix, then start recovery underneath
    // it: this is the second bow-out, past the latch.
    gps.freshPositionGate = Completer<void>();
    await ping.enableAutoPing();
    await tester.pump();
    expect(ping.pingInProgress, isTrue,
        reason: 'the ping latched the flag and awaits its fix');

    ping.setSessionRecoveryInProgress(true);
    gps.freshPositionGate!.complete();
    gps.freshPositionGate = null;
    await tester.pump();

    expect(conn.txTransmits, 0, reason: 'the held ping never transmitted');
    expect(ping.pingInProgress, isFalse,
        reason: 'the bow-out must leave the controls unlocked');
    expect(scheduled, isNotEmpty, reason: 'the lane must be re-armed');

    ping.setSessionRecoveryInProgress(false);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(conn.txTransmits, 1,
        reason: 'the next tick pinged, so the lane was still alive');

    ping.dispose();
  });

  testWidgets('a banked ping released into recovery leaves the lane armed',
      (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final scheduled = <int>[];
    final coverage = _Coverage(RecentCoverage.covered);
    final ping = _build(gps, conn, coverage, scheduled);

    // The opening ping lands in a covered square, so it is banked rather than
    // sent, and the interval is armed behind it.
    await ping.enableAutoPing();
    await tester.pump();
    expect(ping.bankedPing, BankedPingType.tx);
    expect(conn.txTransmits, 0);
    final scheduledBefore = scheduled.length;

    // The first fix in a clear square releases it, which cancels both interval
    // timers before dispatching. Recovery then refuses the dispatched ping, so
    // the re-arm is the only thing keeping the lane alive.
    ping.setSessionRecoveryInProgress(true);
    coverage.answer = RecentCoverage.clear;
    expect(ping.maybeSendBankedPing(_pos(lat: 45.01)), isTrue);
    await tester.pump();

    expect(conn.txTransmits, 0, reason: 'recovery held the released ping');
    expect(scheduled.length, greaterThan(scheduledBefore),
        reason: 'the release cancelled both timers, so one must be re-armed');

    ping.setSessionRecoveryInProgress(false);
    await tester.pump(const Duration(seconds: 31));
    await tester.pump();
    expect(conn.txTransmits, 1,
        reason: 'the re-armed timer carried the lane through recovery');

    ping.dispose();
  });
}
