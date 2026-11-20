import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/models/device_model.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/countdown_timer_service.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';
import 'package:mesh_mapper/services/gps_service.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/recent_coverage_service.dart';
import 'package:mesh_mapper/services/wakelock_service.dart';

/// A TX that comes due while a replacement session is being installed (an
/// expiry recovery, or a group handoff) bows out at the recovery hold. The
/// bow-out re-arms the lane at a full interval so it cannot die, which used to
/// push that ping a whole interval back; now the release pulls the held leg in
/// to about a second, and in Hybrid it is the TX leg that runs, not the
/// discovery the flag had already flipped to.

class _FakeGps implements GpsService {
  @override
  FixAltitude fixAltitudeOf(Position position) => const FixAltitude.unknown();

  Position? position;

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
          {Duration timeout = const Duration(seconds: 3)}) async =>
      position;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeConnection implements MeshCoreConnection {
  int txTransmits = 0;
  int discoveryTransmits = 0;

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
    if (invocation.memberName == #sendDiscoveryRequest) {
      discoveryTransmits++;
      return Future.value(
          (tag: Uint8List.fromList([1, 2, 3, 4]), sentAt: DateTime.now()));
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

Position _pos({double lat = 45.0}) => Position(
      latitude: lat,
      longitude: -75.0,
      timestamp: DateTime.now(),
      accuracy: 5.0,
      altitude: 0.0,
      altitudeAccuracy: 1.0,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 1.0,
    );

PingService _build(
    _FakeGps gps, _FakeConnection conn, List<int> scheduled) {
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
  )..checkRecentCoverage = (lat, lon, kind) => RecentCoverage.clear;
  service.getSessionId = () => 'YOW-20261012-0001';
  service.getNextPingCounter = () => 1;
  service.onAutoPingScheduled = (intervalMs, skipReason) =>
      scheduled.add(intervalMs);
  return service;
}

void main() {
  testWidgets('an Active TX held by the recovery goes out a second after it',
      (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final scheduled = <int>[];
    final ping = _build(gps, conn, scheduled);

    ping.setSessionRecoveryInProgress(true);
    await ping.enableAutoPing();
    await tester.pump();
    expect(conn.txTransmits, 0, reason: 'the hold refused the opening ping');
    expect(scheduled.last, greaterThan(10000),
        reason: 'the bow-out re-armed a full interval as the backstop');

    ping.setSessionRecoveryInProgress(false);
    expect(scheduled.last, PingService.heldTxReleaseDelay.inMilliseconds,
        reason: 'the release pulled the held TX in');
    await tester.pump(const Duration(milliseconds: 900));
    expect(conn.txTransmits, 0);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(conn.txTransmits, 1, reason: 'about a second, not an interval');

    // The lane then runs on its ordinary interval.
    await tester.pump(const Duration(seconds: 40));
    await tester.pump();
    expect(conn.txTransmits, 2);

    ping.dispose();
  });

  testWidgets('a release with nothing held re-arms nothing', (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final scheduled = <int>[];
    final ping = _build(gps, conn, scheduled);

    await ping.enableAutoPing();
    await tester.pump();
    expect(conn.txTransmits, 1);
    final before = scheduled.length;

    ping.setSessionRecoveryInProgress(true);
    ping.setSessionRecoveryInProgress(false);
    expect(scheduled.length, before,
        reason: 'no TX bowed out, so the schedule is untouched');

    ping.dispose();
  });

  testWidgets('in Hybrid the held TX leg is the one that runs', (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final scheduled = <int>[];
    final ping = _build(gps, conn, scheduled);

    // Hybrid opens with a discovery; its TX leg comes due an interval later.
    await ping.enableAutoPing(hybridMode: true);
    await tester.pump();
    expect(conn.discoveryTransmits, 1);
    expect(conn.txTransmits, 0);

    // The swap starts before the TX leg; the leg bows out at the hold.
    ping.setSessionRecoveryInProgress(true);
    await tester.pump(const Duration(seconds: 40));
    await tester.pump();
    expect(conn.txTransmits, 0, reason: 'the hold refused the TX leg');
    expect(conn.discoveryTransmits, 1);

    ping.setSessionRecoveryInProgress(false);
    expect(scheduled.last, PingService.heldTxReleaseDelay.inMilliseconds);
    await tester.pump(const Duration(milliseconds: 1100));
    await tester.pump();
    expect(conn.txTransmits, 1, reason: 'the TX leg ran, a second later');
    expect(conn.discoveryTransmits, 1,
        reason: 'the alternation did not skip to discovery');

    // And the alternation continues: discovery next. The discovery lane has
    // its own 25 m rule against the last discovery, so the phone moves.
    gps.position = _pos(lat: 45.01);
    await tester.pump(const Duration(seconds: 40));
    await tester.pump();
    expect(conn.discoveryTransmits, 2);

    ping.dispose();
  });
}
