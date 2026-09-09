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

/// Toggling Passive off and on must not put a discovery request on the air
/// every time.
///
/// Every Passive start transmits a discovery within milliseconds, and the stop
/// used to null `_lastDiscoveryPosition` ("Reset so first discovery always
/// sends on next start"), so the 25 m rule could not hold a restart on the
/// same spot. The TX side has never worked that way: its anchor lives on
/// GpsService and no stop clears it, so a parked user toggling Active gets
/// nothing on the air. A user-initiated Passive stop now keeps its anchor too.
///
/// A genuine teardown (force disable, disconnect, dispose) still clears it, so
/// a new session always opens with a discovery.

class _FakeGps implements GpsService {
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
  void markActivityPosition(Position position) {}

  @override
  void markPingPosition(Position position) {}

  @override
  Future<Position?> getFreshPosition(
          {Duration timeout = const Duration(seconds: 3)}) async =>
      position;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeConnection implements MeshCoreConnection {
  int discoveryTransmits = 0;

  /// When set, the discovery send parks on this until it completes, which is
  /// how a stop gets to land while the send is in flight.
  Completer<Uint8List>? discoveryGate;

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
      discoveryTransmits++;
      return discoveryGate?.future ??
          Future<Uint8List>.value(Uint8List.fromList([1, 2, 3, 4]));
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

PingService _build(
  _FakeGps gps,
  _FakeConnection conn,
  DiscoveryWindowTimer discoveryWindow, {
  CooldownTimer? cooldown,
}) =>
    PingService(
      gpsService: gps,
      connection: conn,
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: cooldown ?? CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: discoveryWindow,
      deviceId: 'TEST',
    )..checkRecentCoverage = (lat, lon) => RecentCoverage.clear;

void main() {
  testWidgets('a user stop keeps the 25 m anchor, so a restart in place is held',
      (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _build(gps, conn, discoveryWindow);

    // Passive opens with a discovery, which sets the anchor.
    await ping.enableAutoPing(passiveMode: true);
    await tester.pump(const Duration(seconds: 8)); // 7s listening window
    expect(conn.discoveryTransmits, 1);

    // Stop and start again without moving: the toggle a user can hold down.
    for (var i = 0; i < 3; i++) {
      await ping.disableAutoPing();
      await ping.enableAutoPing(passiveMode: true);
      await tester.pump(const Duration(seconds: 8));
    }
    expect(conn.discoveryTransmits, 1,
        reason: 'the 25 m rule held every restart on the same spot');

    // Past 25 m (about 1.1 km north) it transmits again, as it must.
    gps.position = _pos(lat: 45.01);
    await ping.disableAutoPing();
    await ping.enableAutoPing(passiveMode: true);
    await tester.pump(const Duration(seconds: 8));
    expect(conn.discoveryTransmits, 2,
        reason: 'moving past the minimum distance still opens with a discovery');

    await ping.forceDisableAutoPing();
    discoveryWindow.stop();
  });

  testWidgets(
      'a stop parked behind the listening window keeps the anchor as well',
      (tester) async {
    // The other user stop path: the stop lands while the discovery send is
    // still in flight, so it is parked and later drained by the window
    // completion (_executePendingDisable) rather than taken inline. That is
    // where the button reads "Stopping Xs".
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final cooldown = CooldownTimer(); // the drain starts it; stopped below
    final ping = _build(gps, conn, discoveryWindow, cooldown: cooldown);

    final gate = Completer<Uint8List>();
    conn.discoveryGate = gate;
    final starting = ping.enableAutoPing(passiveMode: true);
    await tester.pump(); // the send is parked on the BLE write
    expect(conn.discoveryTransmits, 1);
    expect(ping.pingInProgress, isTrue);

    await ping.disableAutoPing();
    expect(ping.pendingDisable, isTrue, reason: 'parked behind the send');

    conn.discoveryGate = null;
    gate.complete(Uint8List.fromList([1, 2, 3, 4]));
    await starting;
    await tester.pump(const Duration(seconds: 8)); // window closes, drains it
    expect(ping.pendingDisable, isFalse);
    expect(ping.autoPingEnabled, isFalse);

    // Restart on the same spot: held by the 25 m rule, nothing on the air.
    await ping.enableAutoPing(passiveMode: true);
    await tester.pump(const Duration(seconds: 8));
    expect(conn.discoveryTransmits, 1,
        reason: 'the drained stop kept the anchor');

    await ping.forceDisableAutoPing();
    discoveryWindow.stop();
    cooldown.stop();
  });

  testWidgets('a teardown clears the anchor, so a new session opens clean',
      (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _build(gps, conn, discoveryWindow);

    await ping.enableAutoPing(passiveMode: true);
    await tester.pump(const Duration(seconds: 8));
    expect(conn.discoveryTransmits, 1);

    // Not a user toggle: this is the disconnect / mode-switch teardown, and a
    // reconnect on the same spot must not be silently mute.
    await ping.forceDisableAutoPing();
    await ping.enableAutoPing(passiveMode: true);
    await tester.pump(const Duration(seconds: 8));
    expect(conn.discoveryTransmits, 2,
        reason: 'a fresh session always opens with a discovery');

    await ping.forceDisableAutoPing();
    discoveryWindow.stop();
  });
}
