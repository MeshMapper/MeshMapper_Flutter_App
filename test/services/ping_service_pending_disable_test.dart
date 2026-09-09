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

  // Called by the discovery send immediately after it arms its listening
  // window. Missing here, it threw out of the send's own try, so every
  // discovery in this file drained its queued disable down the send-FAILURE
  // path and no test ever reached the armed-window path they are named for.
  @override
  void markActivityPosition(Position position) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

class _FakeConnection implements MeshCoreConnection {
  Completer<Uint8List>? discoveryGate;
  Completer<Uint8List>? traceGate;
  bool sendPingThrows = false;
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
  Future<void> sendPing(String message) async {
    if (sendPingThrows) throw Exception('BLE write failed');
  }

  @override
  Future<Uint8List> sendDiscoveryRequest() =>
      discoveryGate?.future ?? Future.value(Uint8List(4));

  @override
  Future<Uint8List> sendTracePath(Uint8List repeaterIdBytes,
      {int hopBytes = 1}) {
    traceTransmits++;
    return traceGate?.future ?? Future.value(Uint8List(4));
  }

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
  bool held = false;

  @override
  bool get isEnabled => held;

  @override
  Future<void> enable() async => held = true;

  @override
  Future<void> disable() async => held = false;

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

PingService _buildService(
  _FakeGps gps,
  _FakeConnection conn, {
  DiscoveryWindowTimer? discoveryWindowTimer,
  _FakeWakelock? wakelock,
}) =>
    PingService(
      gpsService: gps,
      connection: conn,
      apiQueue: _FakeApiQueue(),
      wakelockService: wakelock ?? _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: discoveryWindowTimer ?? DiscoveryWindowTimer(),
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

  test('a stop drained by its window still releases the wake lock', () {
    // The drain did every other piece of the teardown and left the screen
    // awake. It is the common case for a TX mode, not an edge: sendTxPing holds
    // the in-flight flag for the whole echo window, so a Stop pressed while the
    // button reads "Listening Xs" always parks and always drains through here.
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final wakelock = _FakeWakelock();
      final ping = _buildService(gps, conn, wakelock: wakelock)
        ..getSessionId = (() => 'OTT-20260829-0001')
        ..getNextPingCounter = (() => 1);

      ping.enableAutoPing();
      async.flushMicrotasks();
      expect(wakelock.held, isTrue, reason: 'auto mode holds the wake lock');

      // Stop during the echo window, which is what parks the disable.
      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue);

      async.elapse(const Duration(seconds: 6));
      expect(ping.pendingDisable, isFalse,
          reason: 'the echo window drained the disable');
      expect(wakelock.held, isFalse,
          reason: 'the drain must release the wake lock like every other stop');
      ping.dispose();
    });
  });

  test('a repeat stop cannot strand the disable it is repeating', () {
    // The gap the external Stop lane could reach: a discovery clears
    // pingInProgress the moment it arms its listening window, so a second stop
    // arriving during that window skipped the parking branch and ran the
    // immediate teardown, which disposes the tracker WITHOUT firing the window
    // completion that drains the parked disable. Auto mode then read off in the
    // service and on in the provider, with no cooldown and the foreground
    // service still up, until the 12 second backstop.
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final discGate = Completer<Uint8List>();
      conn.discoveryGate = discGate;
      final ping = _buildService(gps, conn);

      ping.enableAutoPing(passiveMode: true);
      async.flushMicrotasks();
      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue);

      // The discovery lands and arms its 7s window, which clears the in-flight
      // flag while the disable stays parked.
      discGate.complete(Uint8List(4));
      async.flushMicrotasks();
      expect(ping.pingInProgress, isFalse);
      expect(ping.pendingDisable, isTrue);

      // A second stop in that window. It must change nothing.
      expect(ping.disableAutoPing(), completion(isTrue));
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue,
          reason: 'the parked disable is still the one that will run');
      expect(ping.autoPingEnabled, isTrue,
          reason: 'the repeat must not tear the mode down behind the stop');

      // The window still drains it, well before the 12s backstop.
      async.elapse(const Duration(seconds: 8));
      expect(ping.pendingDisable, isFalse);
      expect(ping.autoPingEnabled, isFalse);
      ping.dispose();
    });
  });

  test('a stop during the trace fresh fix parks, it does not tear down', () {
    // The trace lane latched _pingInProgress AFTER its GPS await, where TX and
    // discovery both latch before. A Stop landing in that gap read an idle
    // service, so disableAutoPing took its immediate branch and disposed the
    // TraceTracker, and this send then resumed with nothing to stop it: a trace
    // went on the air for a session the user had already stopped, and the
    // listening window it armed counted against a disposed tracker, so the
    // completion that drains the disable could never fire.
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final discoveryWindow = DiscoveryWindowTimer();
      final ping =
          _buildService(gps, conn, discoveryWindowTimer: discoveryWindow);

      final gate = Completer<Position?>();
      gps.freshPositionGate = gate;

      ping.enableAutoPing(targetedMode: true, targetRepeaterId: '4e');
      async.flushMicrotasks();
      expect(ping.pingInProgress, isTrue,
          reason: 'the trace latches the shared flag before its fresh fix');
      expect(conn.traceTransmits, 0, reason: 'nothing on the air yet');

      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue,
          reason: 'the stop parks behind the trace in flight');
      expect(ping.autoPingEnabled, isTrue,
          reason: 'a parked stop must not tear the mode down under the send');

      // The fix arrives. The trace in flight finishes and arms its window,
      // which is the contract the other two lanes keep.
      gate.complete(gps.position);
      async.flushMicrotasks();
      expect(conn.traceTransmits, 1);
      expect(discoveryWindow.isRunning, isTrue);

      // The tracker survived the parked stop, so its window drains the disable
      // well before the 12s backstop, and the countdown stops with it.
      async.elapse(const Duration(seconds: 6));
      expect(ping.pendingDisable, isFalse,
          reason: 'the trace window end must drain the queued disable');
      expect(ping.autoPingEnabled, isFalse);
      expect(discoveryWindow.isRunning, isFalse,
          reason: 'no countdown may outlive the window it was counting');
      ping.dispose();
    });
  });

  test('a force disable during the trace fresh fix stops it going on the air',
      () {
    // The latch turns a graceful stop into a parked disable, which is what lets
    // the send finish. forceDisableAutoPing consults nothing, so the send has to
    // re-check the lane when it resumes. This is the stop behind a disconnect,
    // the airborne block, a session error and a zone grace or transfer, and the
    // airborne one is the point: that block exists to stop transmitting from an
    // aircraft, and it was letting one more trace out.
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final ping = _buildService(gps, conn);

      final gate = Completer<Position?>();
      gps.freshPositionGate = gate;

      ping.enableAutoPing(targetedMode: true, targetRepeaterId: '4e');
      async.flushMicrotasks();
      expect(ping.pingInProgress, isTrue);
      expect(conn.traceTransmits, 0);

      ping.forceDisableAutoPing();
      async.flushMicrotasks();
      expect(ping.autoPingEnabled, isFalse);

      // The suspended send resumes into a lane that no longer exists.
      gate.complete(gps.position);
      async.flushMicrotasks();
      async.elapse(const Duration(seconds: 10));

      expect(conn.traceTransmits, 0,
          reason: 'no trace may reach the radio after a force disable');
      expect(ping.pingInProgress, isFalse,
          reason: 'the resumed send must not leave the shared flag latched');
      ping.dispose();
    });
  });

  test('a trace that bows out after a parked stop drains it, not the backstop',
      () {
    // The other half of moving the latch: now that a Stop during the fresh fix
    // parks, an attempt that then bows out is the end of the lifecycle that
    // disable was waiting on. Without the drain it would sit out all 12s.
    fakeAsync((async) {
      final gps = _FakeGps()..position = _pos(45.0, -75.0);
      final conn = _FakeConnection();
      final ping = _buildService(gps, conn);

      final gate = Completer<Position?>();
      gps.freshPositionGate = gate;

      ping.enableAutoPing(targetedMode: true, targetRepeaterId: '4e');
      async.flushMicrotasks();
      ping.disableAutoPing();
      async.flushMicrotasks();
      expect(ping.pendingDisable, isTrue);

      // No fix, so the trace bows out without arming anything.
      gate.complete(null);
      async.flushMicrotasks();

      expect(conn.traceTransmits, 0,
          reason: 'a trace with no fix never reaches the radio');
      expect(ping.pendingDisable, isFalse,
          reason: 'the bow-out drains the disable it was holding');
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

  group('a countdown never outlives the lane that owns it', () {
    // The window countdowns are stopped by their completion handlers, which a
    // teardown never reaches: disposing the tracker cancels its timer without
    // firing onWindowComplete. So the stop has to live in the teardown too, or
    // the display keeps counting against a window nobody is listening to.

    test('tearing down discovery mode stops the discovery countdown', () async {
      final discoveryWindow = DiscoveryWindowTimer();
      final ping = _buildService(
        _FakeGps()..position = _pos(45.0, -75.0),
        _FakeConnection(),
        discoveryWindowTimer: discoveryWindow,
      );

      discoveryWindow.start(7000);
      expect(discoveryWindow.isRunning, isTrue);

      await ping.forceDisableAutoPing();

      expect(discoveryWindow.isRunning, isFalse,
          reason: 'the discovery window countdown should stop with its lane');
      discoveryWindow.stop();
    });

    test('tearing down trace mode stops the shared countdown too', () async {
      // forceDisableAutoPing tears down both lanes, and _stopDiscoveryMode()
      // stops the shared window countdown even in trace mode, so the display
      // cannot keep counting after a trace stop. This pins only that: it cannot
      // tell whether TraceTracker.dispose() also stops, because the countdown is
      // stopped either way. The tracker's own teardown (its _endWindow() stop
      // hook and window-timer cancel) is pinned directly in
      // test/services/meshcore/trace_tracker_test.dart.
      final discoveryWindow = DiscoveryWindowTimer();
      final ping = _buildService(
        _FakeGps()..position = _pos(45.0, -75.0),
        _FakeConnection(),
        discoveryWindowTimer: discoveryWindow,
      );

      await ping.enableAutoPing(targetedMode: true, targetRepeaterId: '4E');
      discoveryWindow.start(5000);
      expect(discoveryWindow.isRunning, isTrue);

      await ping.forceDisableAutoPing();

      expect(discoveryWindow.isRunning, isFalse,
          reason: 'the trace window countdown should stop with its lane');
      discoveryWindow.stop();
    });
  });
}
