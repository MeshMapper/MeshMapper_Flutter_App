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
import 'package:mesh_mapper/services/wakelock_service.dart';

/// Airborne block: while the GPS service holds the airborne latch, every ping
/// validator refuses with its own reason, so neither a manual tap nor an auto
/// mode can send in the seconds between detection and the transport closing.

class _FakeGps implements GpsService {
  Position? position;
  bool airborne = false;

  @override
  GpsStatus get status => GpsStatus.locked;

  @override
  Position? get lastPosition => position;

  @override
  bool get isAirborne => airborne;

  @override
  bool isAccuracyAcceptableForPing(Position position) => true;

  @override
  bool canPingAtPosition(Position position) => true;

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

PingService _buildService(_FakeGps gps) => PingService(
      gpsService: gps,
      connection: _FakeConnection(),
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: DiscoveryWindowTimer(),
      deviceId: 'TEST',
    );

void main() {
  test('validators pass on the ground', () {
    final gps = _FakeGps()..position = _pos();
    final ping = _buildService(gps);

    expect(ping.canPing(), PingValidation.valid);
    expect(ping.canPingManual(), PingValidation.valid);
    expect(ping.canStartAutoMode(), PingValidation.valid);
  });

  test('validators refuse with the airborne reason while the latch is set',
      () {
    final gps = _FakeGps()
      ..position = _pos()
      ..airborne = true;
    final ping = _buildService(gps);

    expect(ping.canPing(), PingValidation.airborne);
    expect(ping.canPingManual(), PingValidation.airborne);
    expect(ping.canStartAutoMode(), PingValidation.airborne);
    expect(PingValidation.airborne.message,
        'Wardriving from an aircraft is not allowed');
  });
}
