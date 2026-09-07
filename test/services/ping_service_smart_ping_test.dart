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
  Future<Position?> getFreshPosition(
          {Duration timeout = const Duration(seconds: 3)}) async =>
      position;

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

/// A coverage answer the test can change after the service is built.
class _Coverage {
  RecentCoverage answer;
  _Coverage(this.answer);
}

PingService _buildWith(_FakeGps gps, _Coverage coverage) => PingService(
      gpsService: gps,
      connection: _FakeConnection(),
      apiQueue: _FakeApiQueue(),
      wakelockService: _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: DiscoveryWindowTimer(),
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
    final fired = Completer<void>();
    ping.onAutoPingScheduled = (_, __) {
      if (!fired.isCompleted) fired.complete();
    };

    await ping.enableAutoPing(passiveMode: true);
    await fired.future.timeout(const Duration(seconds: 5));
    expect(ping.bankedPing, BankedPingType.discovery);

    coverage.answer = RecentCoverage.clear;
    expect(ping.maybeSendBankedPing(_pos()), isTrue);
    expect(ping.bankedPing, isNull);

    await ping.forceDisableAutoPing();
  });
}
