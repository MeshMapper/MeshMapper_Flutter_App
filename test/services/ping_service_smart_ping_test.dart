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

/// Smart Pinging: the auto TX validator refuses a fix whose cell is recently
/// covered. Manual pings and the auto-mode start check never look.

class _FakeGps implements GpsService {
  Position? position;
  bool tooClose = false;

  @override
  GpsStatus get status => GpsStatus.locked;

  @override
  Position? get lastPosition => position;

  @override
  bool get isAirborne => false;

  @override
  bool isAccuracyAcceptableForPing(Position position) => true;

  @override
  bool canPingAtPosition(Position position) => !tooClose;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeConnection implements MeshCoreConnection {
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
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('MeshCoreConnection.${invocation.memberName}');
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

Position _pos() => Position(
      latitude: 45.0,
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

PingService _build(_FakeGps gps, RecentCoverage answer) => PingService(
      gpsService: gps,
      connection: _FakeConnection(),
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: DiscoveryWindowTimer(),
      deviceId: 'TEST',
    )..checkRecentCoverage = (lat, lon) => answer;

void main() {
  test('a covered cell blocks the auto validator only', () {
    final gps = _FakeGps()..position = _pos();
    final ping = _build(gps, RecentCoverage.covered);

    expect(ping.canPing(), PingValidation.recentlyCovered);
    expect(ping.canPingManual(), PingValidation.valid);
    expect(ping.canStartAutoMode(), PingValidation.valid);
    expect(PingValidation.recentlyCovered.message,
        'Square recently covered, skipped');
  });

  test('clear and unknown both let the ping go', () {
    final gps = _FakeGps()..position = _pos();
    expect(_build(gps, RecentCoverage.clear).canPing(), PingValidation.valid);
    expect(
        _build(gps, RecentCoverage.unknown).canPing(), PingValidation.valid);
  });

  test('no callback means no check', () {
    final gps = _FakeGps()..position = _pos();
    final ping = _build(gps, RecentCoverage.covered)..checkRecentCoverage = null;
    expect(ping.canPing(), PingValidation.valid);
  });

  test('too close wins over covered', () {
    final gps = _FakeGps()
      ..position = _pos()
      ..tooClose = true;
    expect(_build(gps, RecentCoverage.covered).canPing(),
        PingValidation.tooCloseToLastPing);
  });
}
