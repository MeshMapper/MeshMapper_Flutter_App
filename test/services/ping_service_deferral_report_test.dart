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

class _FakeGps implements GpsService {
  Position? position;
  bool tooClose = false;
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
  bool canPingAtPosition(Position position) => !tooClose;

  @override
  double get configuredMinDistance => 25.0;

  /// A successful discovery send calls this last. Left unimplemented it throws
  /// inside the send's try block, so the send is logged as a failure while a
  /// test that only checks the return value still reads as if it succeeded.
  @override
  void markActivityPosition(Position position) {}

  /// Held open by the test to stand in for the wait a real fresh fix takes,
  /// up to the 3s GPS timeout on a phone.
  Completer<void>? freshPositionGate;

  @override
  Future<Position?> getFreshPosition(
      {Duration timeout = const Duration(seconds: 3)}) async {
    final gate = freshPositionGate;
    if (gate != null) await gate.future;
    return position;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeConnection implements MeshCoreConnection {
  /// Settable so a test can drop the radio after banking a ping.
  @override
  ConnectionStep currentStep = ConnectionStep.connected;

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
    // A released banked discovery reaches the real send path, unlike the
    // deferral tests where validation returns first.
    if (invocation.memberName == #sendDiscoveryRequest) {
      return Future<Uint8List>.value(Uint8List.fromList([1, 2, 3, 4]));
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
  RecentCoverage answer;
  _Coverage(this.answer);
}

/// [discoveryWindowTimer] and [cooldownTimer] are passed in only by the
/// fake-clock tests, which have to stop their 500 ms tickers themselves: they
/// self-cancel off the wall clock, which a pumped test never advances.
PingService _buildWith(
  _FakeGps gps,
  _Coverage coverage, {
  DiscoveryWindowTimer? discoveryWindowTimer,
  CooldownTimer? cooldownTimer,
  MeshCoreConnection? connection,
}) =>
    PingService(
      gpsService: gps,
      connection: connection ?? _FakeConnection(),
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: cooldownTimer ?? CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: discoveryWindowTimer ?? DiscoveryWindowTimer(),
      deviceId: 'TEST',
    )..checkRecentCoverage = (lat, lon) => coverage.answer;

/// Smart pinging reports each held ping through onPingDeferred so the
/// provider can queue a DEFER for the square. One call per deferral, with the
/// fix that was validated, on both the TX and the discovery path. A 25 m skip
/// is not a deferral and reports nothing.

void main() {
  test('a deferred auto TX ping reports the fix and the type', () async {
    final gps = _FakeGps()..position = _pos(lat: 45.1, lon: -75.2);
    final ping = _buildWith(gps, _Coverage(RecentCoverage.covered));
    final reported = <(double, double, BankedPingType)>[];
    ping.onPingDeferred = (lat, lon, held) => reported.add((lat, lon, held));
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));

    expect(reported, [(45.1, -75.2, BankedPingType.tx)]);
    await ping.disableAutoPing();
  });

  test('a deferred passive discovery reports the fresh fix and disc',
      () async {
    final gps = _FakeGps()..position = _pos(lat: 45.3, lon: -75.4);
    final ping = _buildWith(gps, _Coverage(RecentCoverage.covered));
    final reported = <(double, double, BankedPingType)>[];
    ping.onPingDeferred = (lat, lon, held) => reported.add((lat, lon, held));
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing(passiveMode: true);
    await fired.future.timeout(const Duration(seconds: 5));

    expect(reported, [(45.3, -75.4, BankedPingType.discovery)]);
    await ping.disableAutoPing();
  });

  test('a too close skip reports nothing', () async {
    final gps = _FakeGps()
      ..position = _pos()
      ..tooClose = true;
    final ping = _buildWith(gps, _Coverage(RecentCoverage.clear));
    var reports = 0;
    ping.onPingDeferred = (_, __, ___) => reports++;
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));

    expect(ping.skipReason, 'too close');
    expect(reports, 0);
    await ping.disableAutoPing();
  });

  test('no callback wired is fine', () async {
    final gps = _FakeGps()..position = _pos();
    final ping = _buildWith(gps, _Coverage(RecentCoverage.covered));
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };
    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));
    expect(ping.bankedPing, BankedPingType.tx);
    await ping.disableAutoPing();
  });
}
