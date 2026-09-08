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

/// A discovery request must not transmit on top of a ping already in flight.
///
/// `_sendDiscoveryRequest` latched `_pingInProgress` with no reverse guard,
/// while `sendTxPing` returns early on it. The Passive 30s discovery timer
/// fires the request with no guard of its own, so a manual ping still in its
/// listening window would be joined by a discovery packet on the air, and the
/// two paths share the one `_pingInProgress` flag, so the discovery would also
/// clear it out from under the manual ping.

class _FakeGps implements GpsService {
  Position? position;
  int freshCalls = 0;

  /// Held open by the test to keep a ping parked on its fresh fix, so
  /// `_pingInProgress` stays latched (standing in for a ping still listening).
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
    if (invocation.memberName == #sendDiscoveryRequest) {
      discoveryTransmits++;
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

PingService _build(
  _FakeGps gps,
  _FakeConnection conn,
  DiscoveryWindowTimer discoveryWindow,
) =>
    PingService(
      gpsService: gps,
      connection: conn,
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: discoveryWindow,
      deviceId: 'TEST',
    )..checkRecentCoverage = (lat, lon) => RecentCoverage.clear;

void main() {
  testWidgets('a discovery timer skips while a ping is in flight',
      (tester) async {
    final gps = _FakeGps()..position = _pos();
    final conn = _FakeConnection();
    final discoveryWindow = DiscoveryWindowTimer();
    final ping = _build(gps, conn, discoveryWindow);

    // Passive Mode in a clear square: the opening discovery goes out and its
    // listening window closes, which arms the 30s interval timer.
    await ping.enableAutoPing(passiveMode: true);
    await tester.pump(const Duration(seconds: 8)); // 7s listening window
    expect(conn.discoveryTransmits, 1,
        reason: 'the opening discovery transmitted');

    // A ping is now in flight: a TX ping parked on its fresh fix, so
    // _pingInProgress stays latched (this is the manual ping still listening).
    gps.freshPositionGate = Completer<void>();
    unawaited(ping.sendTxPing(manual: false));
    await tester.pump();
    expect(ping.pingInProgress, isTrue,
        reason: 'the TX ping latched the shared flag and awaits its fix');

    final freshBefore = gps.freshCalls;

    // The 30s discovery timer fires while that ping is in flight. It must bail
    // at the guard, before requesting a fresh fix of its own.
    await tester.pump(const Duration(seconds: 31));
    expect(gps.freshCalls, freshBefore,
        reason: 'the discovery returned before requesting a fresh fix');
    expect(conn.discoveryTransmits, 1,
        reason: 'no discovery packet went out while the ping was in flight');

    // Release the parked ping a kilometre away (past the 25m rule, so distance
    // is not what would hold a discovery). Had the discovery not bailed, it
    // would transmit its second packet here; it must not.
    gps.position = _pos(lat: 45.01);
    gps.freshPositionGate!.complete();
    gps.freshPositionGate = null;
    await tester.pump();
    await tester.pump();
    expect(conn.discoveryTransmits, 1,
        reason: 'the discovery never transmitted on top of the in-flight ping');

    // The guard rescheduled the Passive lane instead of stranding it: the
    // interval timer is one-shot and the RX window does not re-arm Passive, so
    // a bare return would stop discovery forever after this one collision. Now
    // the ping has cleared, the next interval must fire a discovery. This is
    // what pins the reschedule (a bare return leaves this at 1).
    await tester.pump(const Duration(seconds: 31));
    expect(conn.discoveryTransmits, 2,
        reason: 'the reschedule re-armed the one-shot Passive discovery timer');

    await ping.forceDisableAutoPing();
    discoveryWindow.stop();
  });
}
