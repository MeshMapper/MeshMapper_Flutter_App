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
import 'package:mesh_mapper/services/wakelock_service.dart';

/// Airborne block: while the GPS service holds the airborne latch, every ping
/// validator refuses with its own reason, so neither a manual tap nor an auto
/// mode can send in the seconds between detection and the transport closing.

class _FakeGps implements GpsService {
  Position? position;
  bool airborne = false;
  int freshCalls = 0;

  /// The fresh fix each send takes is what feeds the latch on iOS in the
  /// background, where the position stream is quiet. This stands in for the
  /// fix that sets it.
  bool airborneOnFreshFix = false;

  /// Held open by the test to park a send on its fresh fix.
  Completer<void>? freshPositionGate;

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
    if (airborneOnFreshFix) airborne = true;
    return position;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeConnection implements MeshCoreConnection {
  int discoveryTransmits = 0;
  int traceTransmits = 0;

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
      return Future<Uint8List>.value(Uint8List.fromList([1, 2, 3, 4]));
    }
    if (invocation.memberName == #sendTracePath) {
      traceTransmits++;
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

PingService _buildService(
  _FakeGps gps, {
  _FakeConnection? connection,
  DiscoveryWindowTimer? discoveryWindowTimer,
}) =>
    PingService(
      gpsService: gps,
      connection: connection ?? _FakeConnection(),
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: discoveryWindowTimer ?? DiscoveryWindowTimer(),
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

  testWidgets('a discovery bows out when its own fresh fix sets the latch',
      (tester) async {
    final gps = _FakeGps()
      ..position = _pos()
      ..airborneOnFreshFix = true;
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _buildService(gps,
        connection: conn, discoveryWindowTimer: discoveryWindow);

    await ping.enableAutoPing(passiveMode: true);
    await tester.pump();

    expect(gps.freshCalls, 1, reason: 'the discovery took its fresh fix');
    expect(conn.discoveryTransmits, 0,
        reason: 'no discovery request may go out from an aircraft');
    expect(ping.pingInProgress, isFalse,
        reason: 'the bow-out must leave the controls unlocked');

    // No reschedule on this path: the provider's airborne handler ends the
    // session, so the lane must not arm another attempt behind it.
    await tester.pump(const Duration(seconds: 31));
    expect(conn.discoveryTransmits, 0,
        reason: 'the airborne bow-out armed no further attempt');

    ping.dispose();
    discoveryWindow.stop();
  });

  testWidgets('a trace bows out when its own fresh fix sets the latch',
      (tester) async {
    final gps = _FakeGps()
      ..position = _pos()
      ..airborneOnFreshFix = true;
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _buildService(gps,
        connection: conn, discoveryWindowTimer: discoveryWindow);

    await ping.enableAutoPing(targetedMode: true, targetRepeaterId: '4e');
    await tester.pump();

    expect(gps.freshCalls, 1, reason: 'the trace took its fresh fix');
    expect(conn.traceTransmits, 0,
        reason: 'no trace may go out from an aircraft');
    expect(ping.pingInProgress, isFalse,
        reason: 'the bow-out must leave the controls unlocked');

    await tester.pump(const Duration(seconds: 31));
    expect(conn.traceTransmits, 0,
        reason: 'the airborne bow-out armed no further attempt');

    ping.dispose();
    discoveryWindow.stop();
  });

  testWidgets('an airborne discovery bow-out still drains a parked stop',
      (tester) async {
    final gps = _FakeGps()
      ..position = _pos()
      ..airborneOnFreshFix = true;
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _buildService(gps,
        connection: conn, discoveryWindowTimer: discoveryWindow);

    // Park the discovery on its fresh fix and stop Passive underneath it, so
    // the stop is waiting on this attempt when the latch sets.
    gps.freshPositionGate = Completer<void>();
    final start = ping.enableAutoPing(passiveMode: true);
    await tester.pump();
    expect(ping.pingInProgress, isTrue);
    expect(await ping.disableAutoPing(), isTrue);
    expect(ping.pendingDisable, isTrue);

    gps.freshPositionGate!.complete();
    gps.freshPositionGate = null;
    await start;
    await tester.pump();

    expect(conn.discoveryTransmits, 0);
    expect(ping.pendingDisable, isFalse,
        reason: 'the parked stop drains here, not at the 12s backstop');
    expect(ping.autoPingEnabled, isFalse, reason: 'the stop completed');

    ping.dispose();
    discoveryWindow.stop();
  });
}
