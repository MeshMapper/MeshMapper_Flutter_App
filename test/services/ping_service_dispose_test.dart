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

/// A disposed PingService must stay silent.
///
/// Both radio-drop paths in the provider dispose the service without a force
/// disable first. A send parked on its fresh fix (or on the BLE write) then
/// resumed into a service whose mode flags still said on, and its skip or
/// failure path re-armed a timer that kept pinging after the radio was gone.

class _FakeGps implements GpsService {
  @override
  FixAltitude fixAltitudeOf(Position position) => const FixAltitude.unknown();

  Position? position;
  int freshCalls = 0;
  bool canPingHere = true;
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
  bool canPingAtPosition(Position position) => canPingHere;

  @override
  double get configuredMinDistance => 25.0;

  @override
  void markActivityPosition(Position position) {}

  @override
  void markPingPosition(Position position) {}

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
  /// Held by the test to park a discovery on its BLE write.
  Completer<void>? discoveryGate;

  /// When set, the parked (or immediate) discovery write throws.
  bool failDiscovery = false;
  int discoveryAttempts = 0;
  int pingTransmits = 0;

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
    if (invocation.memberName == #sendDiscoveryRequest) {
      discoveryAttempts++;
      Future<({Uint8List tag, DateTime sentAt})> send() async {
        final gate = discoveryGate;
        if (gate != null) await gate.future;
        if (failDiscovery) throw StateError('GATT write failed');
        return (tag: Uint8List.fromList([1, 2, 3, 4]), sentAt: DateTime.now());
      }

      return send();
    }
    if (invocation.memberName == #sendPing) {
      pingTransmits++;
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

PingService _build(_FakeGps gps, _FakeConnection conn,
    DiscoveryWindowTimer discoveryWindow) {
  final service = PingService(
    gpsService: gps,
    connection: conn,
    apiQueue: _FakeApiQueue(),
    wakelockService: _FakeWakelock(),
    cooldownTimer: CooldownTimer(),
    manualPingCooldownTimer: ManualPingCooldownTimer(),
    rxWindowTimer: RxWindowTimer(),
    discoveryWindowTimer: discoveryWindow,
    deviceId: 'TEST',
  )..checkRecentCoverage = (lat, lon, kind) => RecentCoverage.clear;
  service.getSessionId = () => 'YYZ-20260914-0001';
  service.getNextPingCounter = () => 1;
  return service;
}

void main() {
  testWidgets('dispose during an Active fresh fix arms no timer',
      (tester) async {
    final gps = _FakeGps()
      ..position = _pos()
      // The resumed ping fails validation, which is the skip path that
      // re-arms the lane.
      ..canPingHere = false
      ..freshPositionGate = Completer<void>();
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _build(gps, conn, discoveryWindow);
    var scheduledAfterDispose = 0;
    var disposed = false;
    ping.onAutoPingScheduled = (_, __) {
      if (disposed) scheduledAfterDispose++;
    };

    unawaited(ping.enableAutoPing());
    await tester.pump();
    expect(gps.freshCalls, 1, reason: 'the opening ping awaits its fix');

    ping.dispose();
    disposed = true;
    gps.freshPositionGate!.complete();
    gps.freshPositionGate = null;
    gps.canPingHere = true;
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));

    expect(scheduledAfterDispose, 0, reason: 'no timer re-armed after dispose');
    expect(gps.freshCalls, 1, reason: 'no further auto ping attempted');
    expect(conn.pingTransmits, 0, reason: 'nothing went on the air');
    expect(ping.autoPingEnabled, isFalse);
    discoveryWindow.stop();
  });

  testWidgets('dispose during a Hybrid fresh fix sends nothing',
      (tester) async {
    final gps = _FakeGps()
      ..position = _pos()
      ..freshPositionGate = Completer<void>();
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _build(gps, conn, discoveryWindow);

    unawaited(ping.enableAutoPing(hybridMode: true));
    await tester.pump();
    expect(gps.freshCalls, 1);

    ping.dispose();
    gps.freshPositionGate!.complete();
    gps.freshPositionGate = null;
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));

    expect(conn.discoveryAttempts, 0);
    expect(conn.pingTransmits, 0);
    expect(gps.freshCalls, 1);
    discoveryWindow.stop();
  });

  testWidgets('a discovery write failing after dispose does not reschedule',
      (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection()
      ..discoveryGate = Completer<void>()
      ..failDiscovery = true;
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _build(gps, conn, discoveryWindow);
    var scheduledAfterDispose = 0;
    var disposed = false;
    ping.onAutoPingScheduled = (_, __) {
      if (disposed) scheduledAfterDispose++;
    };

    unawaited(ping.enableAutoPing(passiveMode: true));
    await tester.pump();
    expect(conn.discoveryAttempts, 1, reason: 'parked on the BLE write');

    ping.dispose();
    disposed = true;
    conn.discoveryGate!.complete();
    conn.discoveryGate = null;
    await tester.pump();
    await tester.pump(const Duration(minutes: 2));

    expect(scheduledAfterDispose, 0);
    expect(conn.discoveryAttempts, 1, reason: 'no retry after dispose');
    discoveryWindow.stop();
  });
}
