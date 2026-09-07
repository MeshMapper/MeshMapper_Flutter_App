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

/// Smart Pinging: the auto TX validator refuses a fix whose cell is recently
/// covered. Manual pings and the auto-mode start check never look.

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

/// [discoveryWindowTimer] is passed in only by the fake-clock tests, which
/// have to stop its 500 ms ticker themselves: it self-cancels off the wall
/// clock, which a pumped test never advances.
PingService _buildWith(
  _FakeGps gps,
  _Coverage coverage, {
  DiscoveryWindowTimer? discoveryWindowTimer,
}) =>
    PingService(
      gpsService: gps,
      connection: _FakeConnection(),
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: discoveryWindowTimer ?? DiscoveryWindowTimer(),
      deviceId: 'TEST',
    )..checkRecentCoverage = (lat, lon) => coverage.answer;

PingService _build(_FakeGps gps, RecentCoverage answer) =>
    _buildWith(gps, _Coverage(answer));

void main() {
  test('a covered cell blocks the auto validator only', () {
    final gps = _FakeGps()..position = _pos();
    final ping = _build(gps, RecentCoverage.covered);

    expect(ping.canPing(), PingValidation.recentlyCovered);
    expect(ping.canPingManual(), PingValidation.valid);
    expect(ping.canStartAutoMode(), PingValidation.valid);
    expect(PingValidation.recentlyCovered.message,
        'Square recently covered, deferred');
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

  test('an auto attempt in a covered cell names the skip reason', () async {
    final gps = _FakeGps()..position = _pos();
    final ping = _build(gps, RecentCoverage.covered);
    final scheduled = <String?>[];
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (intervalMs, reason) {
      scheduled.add(reason);
      if (!fired.isCompleted) fired.complete();
    };

    // Active Mode sends its first auto ping straight away, and that attempt
    // runs the auto validator. Nothing is transmitted: the covered cell
    // returns before the send, so the fake radio is never asked to write.
    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));

    expect(ping.skipReason, PingService.skipReasonRecentlyCovered);
    expect(scheduled, [PingService.skipReasonRecentlyCovered]);

    await ping.disableAutoPing();
  });

  test('too close wins over covered', () {
    final gps = _FakeGps()
      ..position = _pos()
      ..tooClose = true;
    expect(_build(gps, RecentCoverage.covered).canPing(),
        PingValidation.tooCloseToLastPing);
  });

  test('a deferred auto TX ping is banked', () async {
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

  test('a too close skip leaves the bank alone', () async {
    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.covered);
    final ping = _buildWith(gps, coverage);
    final reasons = <String?>[];
    var scheduled = Completer<void>();
    ping.onAutoPingScheduled = (_, reason) {
      reasons.add(reason);
      if (!scheduled.isCompleted) scheduled.complete();
    };

    await ping.enableAutoPing();
    await scheduled.future.timeout(const Duration(seconds: 5));
    expect(ping.bankedPing, BankedPingType.tx);

    // Stationary in the covered square. sendTxPing(manual: false) is the very
    // call the auto timer makes, so this runs the real auto send path rather
    // than the pure validator: the distance check comes first, so the attempt
    // skips as 'too close' and never reaches the coverage check that armed
    // the bank. Driving it directly beats waiting out the 30s interval.
    scheduled = Completer<void>();
    gps.tooClose = true;
    await ping.sendTxPing(manual: false);
    await scheduled.future.timeout(const Duration(seconds: 5));

    // The skip reason is the proof the send path really took that branch: a
    // test that only asked canPing() would pass without ever running it.
    expect(ping.skipReason, 'too close');
    expect(reasons.last, 'too close');
    expect(ping.bankedPing, BankedPingType.tx,
        reason: 'a distance skip must not discard a Smart Ping deferral');

    await ping.disableAutoPing();
  });

  test('stopping auto mode empties the bank', () async {
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
    expect(ping.bankedPing, isNull);
  });

  test('a deferred passive discovery is banked', () async {
    final gps = _FakeGps()..position = _pos();
    final ping = _buildWith(gps, _Coverage(RecentCoverage.covered));
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    // Passive Mode sends its first discovery request straight away, and the
    // covered square returns before the radio is asked for anything.
    await ping.enableAutoPing(passiveMode: true);
    await fired.future.timeout(const Duration(seconds: 5));

    expect(ping.bankedPing, BankedPingType.discovery);
    expect(ping.skipReason, PingService.skipReasonRecentlyCovered);
    await ping.disableAutoPing();
  });

  test('clearBankedPing empties the bank', () async {
    final gps = _FakeGps()..position = _pos();
    final ping = _buildWith(gps, _Coverage(RecentCoverage.covered));
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));
    expect(ping.bankedPing, BankedPingType.tx);

    ping.clearBankedPing();
    expect(ping.bankedPing, isNull);
    await ping.disableAutoPing();
  });

  test('a clear square releases the banked TX ping', () async {
    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.covered);
    final ping = _buildWith(gps, coverage);
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));
    expect(ping.bankedPing, BankedPingType.tx);

    coverage.answer = RecentCoverage.clear;
    expect(ping.maybeSendBankedPing(_pos()), isTrue);
    expect(ping.bankedPing, isNull);
    expect(ping.skipReason, isNull,
        reason: 'the deferral left this set to the recently covered reason');
    // Proof the ping was really dispatched and not just dropped: sendTxPing
    // raises this flag before its first await, so it is already true by the
    // time the release returns.
    expect(ping.pingInProgress, isTrue);

    await ping.forceDisableAutoPing();
  });

  test('airborne holds the bank on a clear square', () async {
    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.covered);
    final ping = _buildWith(gps, coverage);
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));
    expect(ping.bankedPing, BankedPingType.tx);

    // Everything else says release: the square is clear and the distance is
    // satisfied. Only the latch stands in the way.
    coverage.answer = RecentCoverage.clear;
    gps.airborne = true;
    expect(ping.maybeSendBankedPing(_pos()), isFalse);
    expect(ping.bankedPing, BankedPingType.tx,
        reason: 'a refused release must leave the ping banked');
    expect(ping.pingInProgress, isFalse);

    // Landing releases it. Proves the refusal above was the airborne guard
    // and not one of the other early returns.
    gps.airborne = false;
    expect(ping.maybeSendBankedPing(_pos()), isTrue);
    expect(ping.bankedPing, isNull);
    expect(ping.pingInProgress, isTrue);

    await ping.forceDisableAutoPing();
  });

  test('a still covered square holds the bank', () async {
    final gps = _FakeGps()..position = _pos();
    final ping = _buildWith(gps, _Coverage(RecentCoverage.covered));
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));

    expect(ping.maybeSendBankedPing(_pos()), isFalse);
    expect(ping.bankedPing, BankedPingType.tx);

    await ping.disableAutoPing();
  });

  test('unknown coverage does not release the bank', () async {
    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.covered);
    final ping = _buildWith(gps, coverage);
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));

    coverage.answer = RecentCoverage.unknown;
    expect(ping.maybeSendBankedPing(_pos()), isFalse,
        reason: 'no tile loaded here; the interval tick fails open instead');
    expect(ping.bankedPing, BankedPingType.tx);

    await ping.disableAutoPing();
  });

  test('the 25m rule still gates a banked release', () async {
    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.covered);
    final ping = _buildWith(gps, coverage);
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing();
    await fired.future.timeout(const Duration(seconds: 5));

    coverage.answer = RecentCoverage.clear;
    gps.tooClose = true;
    expect(ping.maybeSendBankedPing(_pos()), isFalse);
    expect(ping.bankedPing, BankedPingType.tx);

    await ping.disableAutoPing();
  });

  test('an empty bank releases nothing', () {
    final gps = _FakeGps()..position = _pos();
    final ping = _buildWith(gps, _Coverage(RecentCoverage.clear));
    expect(ping.maybeSendBankedPing(_pos()), isFalse);
  });

  test('a clear square releases the banked discovery', () async {
    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.covered);
    final ping = _buildWith(gps, coverage);
    final scheduled = <int>[];
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (intervalMs, __) {
      scheduled.add(intervalMs);
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing(passiveMode: true);
    await fired.future.timeout(const Duration(seconds: 5));
    expect(ping.bankedPing, BankedPingType.discovery);

    coverage.answer = RecentCoverage.clear;
    final scheduledAtRelease = scheduled.length;
    expect(ping.maybeSendBankedPing(_pos()), isTrue);
    expect(ping.bankedPing, isNull);
    expect(ping.skipReason, isNull,
        reason: 'the deferral left this set to the recently covered reason');

    // Proof the ping was really dispatched: the tracker only starts listening
    // once the radio has answered the request.
    await Future<void>.delayed(Duration.zero);
    expect(ping.isDiscoveryListening, isTrue);

    // And proof it took the success path rather than the catch, which is easy
    // to land in by accident when a fake throws: a failed send reschedules on
    // the spot, a successful one waits out its window first.
    expect(scheduled.length, scheduledAtRelease,
        reason: 'a successful send schedules nothing until its window closes');

    await ping.forceDisableAutoPing();
  });

  // The two below need a second discovery, which is 37s of timers away in real
  // time. testWidgets runs the body on a fake clock, so tester.pump() buys that
  // wait for nothing.

  testWidgets('the 25m rule gates a banked discovery too', (tester) async {
    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.clear);
    final discoveryWindow = DiscoveryWindowTimer();
    final ping =
        _buildWith(gps, coverage, discoveryWindowTimer: discoveryWindow);

    // A clear square, so the opening discovery really goes out and anchors the
    // distance rule at 45.0, -75.0.
    await ping.enableAutoPing(passiveMode: true);
    await tester.pump(const Duration(seconds: 8)); // the 7s listening window

    // A kilometre north and now covered, so the next discovery banks instead
    // of sending. The anchor stays where the first one went out.
    gps.position = _pos(lat: 45.01);
    coverage.answer = RecentCoverage.covered;
    await tester.pump(const Duration(seconds: 31)); // the 30s interval
    expect(ping.bankedPing, BankedPingType.discovery);

    // Back on top of that anchor. The square is clear, so the distance rule is
    // the only thing left that can hold the bank.
    coverage.answer = RecentCoverage.clear;
    expect(ping.maybeSendBankedPing(_pos()), isFalse);
    expect(ping.bankedPing, BankedPingType.discovery);

    // The same bank releases a kilometre out, which is what makes the refusal
    // above about distance and nothing else.
    expect(ping.maybeSendBankedPing(_pos(lat: 45.01)), isTrue);

    // Let that release land before tearing down, so the timers it arms belong
    // to a live session and go away with it.
    await tester.pump();
    await ping.forceDisableAutoPing();
    discoveryWindow.stop();
  });

  testWidgets('an in flight discovery holds the banked ping', (tester) async {
    // The window this covers: a discovery request is past its guards but still
    // waiting on its own fresh fix. The GPS stream calls maybeSendBankedPing on
    // every fix, so a bank released in that gap would transmit on top of the
    // discovery, doubling the airtime and running both listening windows at
    // once.
    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.covered);
    final discoveryWindow = DiscoveryWindowTimer();
    final ping =
        _buildWith(gps, coverage, discoveryWindowTimer: discoveryWindow);

    // Hybrid opens on discovery, which the covered square banks, and hands the
    // next leg to TX.
    await ping.enableAutoPing(hybridMode: true);
    expect(ping.bankedPing, BankedPingType.discovery);

    // The TX leg lands in the same covered square, so the bank is a TX ping
    // and the leg after it is discovery again.
    await tester.pump(const Duration(seconds: 24));
    expect(ping.bankedPing, BankedPingType.tx);

    // Hold that discovery's fresh fix open.
    gps.freshPositionGate = Completer<void>();
    await tester.pump(const Duration(seconds: 24));
    expect(ping.pingInProgress, isTrue,
        reason: 'the discovery is under way, waiting on its fix');

    // A fix lands in a clear square while the discovery is still waiting.
    coverage.answer = RecentCoverage.clear;
    expect(ping.maybeSendBankedPing(_pos(lat: 45.01)), isFalse,
        reason: 'a banked ping must not go out on top of a live discovery');
    expect(ping.bankedPing, BankedPingType.tx);

    // Control: let that discovery finish into a covered square, so it banks
    // itself and leaves nothing in flight. The very same clear square now
    // releases, which is what makes the refusal above about the discovery and
    // not about one of the other guards.
    coverage.answer = RecentCoverage.covered;
    gps.freshPositionGate!.complete();
    await tester.pump();
    expect(ping.pingInProgress, isFalse);
    expect(ping.bankedPing, BankedPingType.discovery);

    coverage.answer = RecentCoverage.clear;
    expect(ping.maybeSendBankedPing(_pos(lat: 45.01)), isTrue);

    await tester.pump();
    await ping.forceDisableAutoPing();
    discoveryWindow.stop();
  });

  testWidgets('a released hybrid discovery leaves TX as the next leg',
      (tester) async {
    // Hybrid announces its next leg through the interval it schedules: the
    // wait is the ping interval less that leg's listening window, 5s for TX
    // and 7s for discovery. That is the only view of the alternation from
    // outside the class.
    const txLegWaitMs = 25000;
    const discoveryLegWaitMs = 23000;

    final gps = _FakeGps()..position = _pos();
    final coverage = _Coverage(RecentCoverage.covered);
    final discoveryWindow = DiscoveryWindowTimer();
    final ping =
        _buildWith(gps, coverage, discoveryWindowTimer: discoveryWindow);
    final scheduled = <int>[];
    ping.onAutoPingScheduled = (intervalMs, _) => scheduled.add(intervalMs);

    // Hybrid opens on discovery, and the covered square banks it. Hybrid has
    // already moved the flag on to TX by the time enableAutoPing returns,
    // which is exactly the state the release must not toggle.
    await ping.enableAutoPing(hybridMode: true);
    expect(ping.bankedPing, BankedPingType.discovery);
    expect(scheduled, [discoveryLegWaitMs]);

    coverage.answer = RecentCoverage.clear;
    expect(ping.maybeSendBankedPing(_pos()), isTrue);

    // The leg after the released discovery is scheduled when its 7s window
    // closes.
    await tester.pump(const Duration(seconds: 8));
    expect(scheduled.last, txLegWaitMs,
        reason: 'a released discovery must hand the next leg to TX');

    await ping.forceDisableAutoPing();
    discoveryWindow.stop();
  });
}
