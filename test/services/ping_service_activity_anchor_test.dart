import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
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

/// #501: only the TX path updated the shared display anchor, so the map's
/// distance-to-previous-ping readout stayed at the session start in Trace and
/// Passive modes. Discovery and trace sends must mark the display-only
/// activity anchor (and must NOT touch the TX skip anchor).

class _FakeGps implements GpsService {
  Position? position;
  final List<Position> activityMarks = [];
  final List<Position> pingMarks = [];

  @override
  GpsStatus get status => GpsStatus.locked;

  @override
  Position? get lastPosition => position;

  @override
  Future<Position?> getFreshPosition(
          {Duration timeout = const Duration(seconds: 3)}) =>
      Future.value(position);

  @override
  bool isAccuracyAcceptableForPing(Position position) => true;

  @override
  bool canPingAtPosition(Position position) => true;

  @override
  double get configuredMinDistance => 25.0;

  @override
  void markPingPosition(Position position) => pingMarks.add(position);

  @override
  void markActivityPosition(Position position) => activityMarks.add(position);

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
  Future<Uint8List> sendDiscoveryRequest() => Future.value(Uint8List(4));

  @override
  Future<Uint8List> sendTracePath(Uint8List repeaterIdBytes,
          {int hopBytes = 1}) =>
      Future.value(Uint8List(4));

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

Position _pos(double lat, double lon) => Position(
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

PingService _buildService(_FakeGps gps, _FakeConnection conn) => PingService(
      gpsService: gps,
      connection: conn,
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: DiscoveryWindowTimer(),
      deviceId: 'TEST',
    );

void main() {
  test('a successful discovery send marks the display anchor', () {
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final ping = _buildService(gps, conn);

      ping.enableAutoPing(passiveMode: true);
      async.flushMicrotasks();

      expect(gps.activityMarks, [gps.position],
          reason: 'the readout must follow the discovery position');
      expect(gps.pingMarks, isEmpty,
          reason: 'a discovery must not move the TX skip anchor');
      ping.dispose();
    });
  });

  test('a successful trace send marks the display anchor', () {
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final ping = _buildService(gps, conn);

      ping.enableAutoPing(targetedMode: true, targetRepeaterId: '4e');
      async.flushMicrotasks();

      expect(gps.activityMarks, [gps.position],
          reason: 'the readout must follow the trace position');
      expect(gps.pingMarks, isEmpty,
          reason: 'a trace must not move the TX skip anchor');
      ping.dispose();
    });
  });
}
