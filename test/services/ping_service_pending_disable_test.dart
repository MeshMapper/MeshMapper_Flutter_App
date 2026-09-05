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

/// #496: a disable queued while a ping is in flight must be executed by
/// whatever ends that ping's lifecycle (skip, failure, or listening window),
/// never left for the 12s timeout backstop (or, on v1.3.0, the next ping).
///
/// The production capture: the user's stop landed during an auto ping's GPS
/// fetch; the ping was then skipped as too-close, so no RX window was armed
/// and nothing drained the flag. Ping controls stayed locked until the NEXT
/// ping's window drained it 41s later.

class _FakeGps implements GpsService {
  Position? position;
  bool tooClose = false;
  Completer<Position?>? freshPositionGate;

  @override
  GpsStatus get status => GpsStatus.locked;

  @override
  Position? get lastPosition => position;

  @override
  Future<Position?> getFreshPosition(
          {Duration timeout = const Duration(seconds: 3)}) =>
      freshPositionGate?.future ?? Future.value(position);

  @override
  bool isAccuracyAcceptableForPing(Position position) => true;

  @override
  bool get isAirborne => false;

  @override
  bool canPingAtPosition(Position position) => !tooClose;

  @override
  double get configuredMinDistance => 25.0;

  @override
  void markPingPosition(Position position) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeConnection implements MeshCoreConnection {
  Completer<Uint8List>? discoveryGate;
  Completer<Uint8List>? traceGate;
  bool sendPingThrows = false;

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
  Future<void> sendPing(String message) async {
    if (sendPingThrows) throw Exception('BLE write failed');
  }

  @override
  Future<Uint8List> sendDiscoveryRequest() =>
      discoveryGate?.future ?? Future.value(Uint8List(4));

  @override
  Future<Uint8List> sendTracePath(Uint8List repeaterIdBytes,
          {int hopBytes = 1}) =>
      traceGate?.future ?? Future.value(Uint8List(4));

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
  test('a disable queued during a skipped auto ping executes immediately', () {
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final ping = _buildService(gps, conn);

      final gate = Completer<Position?>();
      gps.freshPositionGate = gate;

      ping.enableAutoPing();
      async.flushMicrotasks();
      expect(ping.pingInProgress, isTrue,
          reason: 'initial auto ping should be parked on the GPS fetch');

      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue,
          reason: 'disable should queue while the ping is in flight');

      // The ping resumes and is skipped by the 25m check: no RX window armed.
      gps.tooClose = true;
      gate.complete(gps.position);
      async.flushMicrotasks();

      expect(ping.pendingDisable, isFalse,
          reason: 'a skipped ping must drain the queued disable itself');
      expect(ping.autoPingEnabled, isFalse,
          reason: 'auto mode must stop when the skipped ping ends');
      ping.dispose();
    });
  });

  test('a disable queued during a failed TX send executes immediately', () {
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection()..sendPingThrows = true;
      final ping = _buildService(gps, conn)
        ..getSessionId = (() => 'OTT-20260829-0001')
        ..getNextPingCounter = (() => 1);

      final gate = Completer<Position?>();
      gps.freshPositionGate = gate;

      ping.enableAutoPing();
      async.flushMicrotasks();
      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue);

      gate.complete(gps.position);
      async.flushMicrotasks();

      expect(ping.pendingDisable, isFalse,
          reason: 'a ping whose BLE send failed must drain the disable');
      expect(ping.autoPingEnabled, isFalse);
      ping.dispose();
    });
  });

  test('passive mode: discovery window completion executes a queued disable',
      () {
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final discGate = Completer<Uint8List>();
      conn.discoveryGate = discGate;
      final ping = _buildService(gps, conn);

      ping.enableAutoPing(passiveMode: true);
      async.flushMicrotasks();
      expect(ping.pingInProgress, isTrue,
          reason: 'discovery send should be parked on the BLE write');

      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue);

      discGate.complete(Uint8List(4));
      async.flushMicrotasks();

      // The 7s discovery window runs out; well before the 12s backstop.
      async.elapse(const Duration(seconds: 8));

      expect(ping.pendingDisable, isFalse,
          reason: 'the discovery window end must drain the queued disable');
      expect(ping.autoPingEnabled, isFalse);
      ping.dispose();
    });
  });

  test('targeted mode: trace window completion executes a queued disable', () {
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final traceGate = Completer<Uint8List>();
      conn.traceGate = traceGate;
      final ping = _buildService(gps, conn);

      ping.enableAutoPing(targetedMode: true, targetRepeaterId: '4e');
      async.flushMicrotasks();
      expect(ping.pingInProgress, isTrue,
          reason: 'trace send should be parked on the BLE write');

      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue);

      traceGate.complete(Uint8List(4));
      async.flushMicrotasks();

      // The 5s trace window runs out; well before the 12s backstop.
      async.elapse(const Duration(seconds: 6));

      expect(ping.pendingDisable, isFalse,
          reason: 'the trace window end must drain the queued disable');
      expect(ping.autoPingEnabled, isFalse);
      ping.dispose();
    });
  });

  test('a throwing provider callback cannot escape the disable drain', () {
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final discGate = Completer<Uint8List>();
      conn.discoveryGate = discGate;
      final ping = _buildService(gps, conn)
        ..onPendingDisableComplete =
            (() async => throw Exception('provider teardown failed'));

      ping.enableAutoPing(passiveMode: true);
      async.flushMicrotasks();
      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue);

      discGate.complete(Uint8List(4));
      async.flushMicrotasks();

      // The window-complete drain runs from a void tracker callback: nothing
      // awaits it, so an escaping error would be an unhandled async error.
      async.elapse(const Duration(seconds: 8));

      expect(ping.pendingDisable, isFalse);
      expect(ping.autoPingEnabled, isFalse);
      ping.dispose();
    });
  });

  test('a successful TX ping still drains the disable at RX window end', () {
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final ping = _buildService(gps, conn)
        ..getSessionId = (() => 'OTT-20260829-0001')
        ..getNextPingCounter = (() => 1);

      final gate = Completer<Position?>();
      gps.freshPositionGate = gate;

      ping.enableAutoPing();
      async.flushMicrotasks();
      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue);

      gate.complete(gps.position);
      async.flushMicrotasks();

      // Ping transmitted; the RX window is live. The disable must wait for it
      // so in-flight echoes are still collected...
      expect(ping.pingInProgress, isTrue,
          reason: 'RX window should be running after a successful send');
      expect(ping.pendingDisable, isTrue,
          reason: 'the disable must NOT preempt a live RX window');

      // ...and execute when the window ends.
      async.elapse(const Duration(seconds: 6));

      expect(ping.pendingDisable, isFalse);
      expect(ping.autoPingEnabled, isFalse);
      ping.dispose();
    });
  });
}
