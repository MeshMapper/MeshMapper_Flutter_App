import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/models/device_model.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/countdown_timer_service.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';
import 'package:mesh_mapper/services/gps_service.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/meshcore/scope_lease.dart';
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/recent_coverage_service.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_discovery_rules.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_runner.dart';
import 'package:mesh_mapper/services/wakelock_service.dart';

import 'meshcore/scope_test_support.dart' as lease_support;

/// The scope runner rides alongside the discovery schedule and must never
/// move it: these tests run the real PingService on a fake radio and compare
/// every scheduled moment with and without a runner.

class _FakeGps implements GpsService {
  @override
  FixAltitude fixAltitudeOf(Position position) => const FixAltitude.unknown();

  double _lat = 45.0;
  bool tooClose = false;

  Position get _next {
    // Each fresh fix is 100 m further north, so the 25 m rule never holds a
    // discovery back.
    _lat += 0.0009;
    return _pos(_lat, -75.0);
  }

  Position? _last;

  @override
  GpsStatus get status => GpsStatus.locked;

  @override
  Position? get lastPosition => _last ??= _pos(_lat, -75.0);

  @override
  Future<Position?> getFreshPosition(
      {Duration timeout = const Duration(seconds: 3)}) async {
    _last = _next;
    return _last;
  }

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
  void markActivityPosition(Position position) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('GpsService.${invocation.memberName}');
}

/// Answers every discovery with [replies] (own tag unless told otherwise),
/// 300 ms after the send.
class _FakeConnection implements MeshCoreConnection {
  final StreamController<({Uint8List raw, double snr, int rssi})> control =
      StreamController.broadcast(sync: true);
  final List<String> events = [];
  final DateTime t0;
  List<({int keyFill, int type, bool own, int rssi})> replies = [
    (keyFill: 0x11, type: DiscoveryConstants.nodeTypeRepeater, own: true, rssi: -70),
    (keyFill: 0x22, type: DiscoveryConstants.nodeTypeRepeater, own: true, rssi: -80),
  ];
  Duration replyDelay = const Duration(milliseconds: 300);

  /// Runs at the moment a discovery reaches the radio.
  void Function()? onDiscoveryWrite;

  _FakeConnection(this.t0);

  int get _ms => clock.now().difference(t0).inMilliseconds;

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
      control.stream;

  @override
  Stream<Uint8List> get traceDataStream => const Stream.empty();

  @override
  Future<void> sendPing(String message, {void Function()? onWire}) async {
    onWire?.call();
    events.add('tx@$_ms');
  }

  @override
  Future<({Uint8List tag, DateTime sentAt})> sendDiscoveryRequest() async {
    onDiscoveryWrite?.call();
    events.add('disc@$_ms');
    const own = [1, 2, 3, 4];
    for (final r in replies) {
      Timer(replyDelay, () {
        control.add((
          raw: Uint8List.fromList([
            0,
            DiscoveryConstants.discoverRespFlag | r.type,
            20,
            ...(r.own ? own : const [9, 9, 9, 9]),
            ...List<int>.filled(32, r.keyFill),
          ]),
          snr: 5.0,
          rssi: r.rssi,
        ));
      });
    }
    return (tag: Uint8List.fromList(own), sentAt: clock.now());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('MeshCoreConnection.${invocation.memberName}');
}

class _FakeApiQueue implements ApiQueueService {
  /// When set, every DISC write parks on it.
  Completer<void>? discGate;
  int discWrites = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #enqueueDisc) {
      discWrites++;
      return discGate?.future ?? Future<void>.value();
    }
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
      timestamp: DateTime(2026),
      accuracy: 5.0,
      altitude: 0.0,
      altitudeAccuracy: 1.0,
      heading: 0.0,
      headingAccuracy: 1.0,
      speed: 0.0,
      speedAccuracy: 1.0,
    );

/// A radio the test drives: a lease is held until [endLeasePhase] (or, in
/// auto mode, for [autoLease]), then the answer wait runs until the wait
/// ends or the test answers. Records what the runner asked and fails on
/// overlap.
class _ControlledRadio implements ScopeRadio {
  final List<({String key, Duration? answerWait, DateTime at})> asks = [];
  final List<String> overlaps = [];
  bool leaseHeld = false;
  bool inWait = false;

  /// Null holds each lease until [endLeasePhase].
  Duration? autoLease = const Duration(milliseconds: 100);

  /// When set, the answer wait ends only when the test completes this, and
  /// it returns that outcome even after a cancel: an answer that arrives
  /// after the runner was stopped.
  Completer<ScopeRequestOutcome>? lateAnswer;
  Completer<void>? _leasePhase;

  void endLeasePhase() => _leasePhase?.complete();

  @override
  Future<ScopeLeaseHandle?> acquire(
      {required Duration admissionWait,
      required ScopeCancelToken cancel}) async {
    if (leaseHeld || inWait) overlaps.add('overlap');
    if (cancel.isCancelled) return null;
    leaseHeld = true;
    return _Lease(this, cancel);
  }
}

class _Lease implements ScopeLeaseHandle {
  final _ControlledRadio radio;
  final ScopeCancelToken cancel;
  _Lease(this.radio, this.cancel);

  @override
  List<ContactRecord> get unrestored => const [];

  @override
  Future<void> release() async => radio.leaseHeld = false;

  @override
  Future<bool> restore(ContactRecord original) async => true;

  Future<bool> _until(Future<void> f) {
    final done = Completer<bool>();
    f.then((_) {
      if (!done.isCompleted) done.complete(true);
    });
    cancel.whenCancelled.then((_) {
      if (!done.isCompleted) done.complete(false);
    });
    return done.future;
  }

  @override
  Future<ScopeRequestOutcome> requestScopes(Uint8List pubkey, Uint8List request,
      {required Duration? answerWait,
      required DateTime notAfter,
      void Function(Duration wait)? onSent}) async {
    final key = pubkey
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    radio.asks.add((key: key, answerWait: answerWait, at: clock.now()));
    final auto = radio.autoLease;
    final phase = radio._leasePhase = Completer<void>();
    final leaseDone = auto == null
        ? phase.future
        : Future<void>.delayed(auto);
    if (!await _until(leaseDone)) {
      radio.leaseHeld = false;
      return const ScopeAborted();
    }
    radio.leaseHeld = false;
    radio.inWait = true;
    final late = radio.lateAnswer;
    if (late != null) {
      final outcome = await late.future;
      radio.inWait = false;
      return outcome;
    }
    var wait = answerWait ?? const Duration(seconds: 3);
    final end = clock.now().add(wait);
    if (notAfter.isBefore(end)) wait = notAfter.difference(clock.now());
    final ran = await _until(Future<void>.delayed(wait));
    radio.inWait = false;
    return ran ? const ScopeNoAnswer() : const ScopeAborted();
  }
}

class _Scenario {
  final FakeAsync async;
  final DateTime t0;
  final _FakeGps gps = _FakeGps();
  late final _FakeConnection conn = _FakeConnection(t0);
  final _FakeApiQueue queue = _FakeApiQueue();
  final _ControlledRadio radio = _ControlledRadio();
  final List<bool> badge = [];
  final List<({DateTime hardStop, DateTime at, DateTime? earliest})> built = [];
  final List<ScopeRunner> runners = [];
  final List<ScopeCancelToken> tokens = [];
  final List<ScopeLogEntry> logged = [];
  int enqueued = 0;

  /// What Smart Pinging answers for every fix (see [smartPing]).
  RecentCoverage coverage = RecentCoverage.clear;

  /// Runs after every schedule the service announces.
  void Function(int ms, String? reason)? onScheduled;
  late final PingService ping;

  _Scenario(this.async,
      {bool withRunner = true, int intervalMs = 30000, bool smartPing = false})
      : t0 = clock.now() {
    ping = PingService(
      gpsService: gps,
      connection: conn,
      apiQueue: queue,
      wakelockService: _FakeWakelock(),
      cooldownTimer: CooldownTimer(),
      manualPingCooldownTimer: ManualPingCooldownTimer(),
      rxWindowTimer: RxWindowTimer(),
      discoveryWindowTimer: DiscoveryWindowTimer(),
      deviceId: 'TEST',
    )
      ..getSessionId = (() => 'OTT-20260926-0001')
      ..getNextPingCounter = (() => 1)
      ..onAutoPingScheduled = (ms, reason) {
        conn.events.add('sched$ms@${clock.now().difference(t0).inMilliseconds}');
        onScheduled?.call(ms, reason);
      };
    if (smartPing) ping.checkRecentCoverage = (_, __) => coverage;
    ping.setAutoPingInterval(intervalMs);
    if (withRunner) {
      ping.scopeRunnerFactory = ({required hardStop, required cancel}) {
        built.add((
          hardStop: hardStop,
          at: clock.now(),
          earliest: ping.earliestNextDiscoveryAt
        ));
        tokens.add(cancel);
        final runner = ScopeRunner(
          radio: radio,
          cancel: cancel,
          hardStop: hardStop,
          refreshDays: () => 14,
          deviceKey: () => 'DEVICEKEY',
          serverInfo: (_) => (onList: false, checkedAt: null),
          cache: ScopeQueryCache.fromJson(null),
          budget: ScopeHourlyBudget(save: (_) async {}),
          enqueue: (_, __) async {
            enqueued++;
            return true;
          },
          nowSec: () => clock.now().millisecondsSinceEpoch ~/ 1000,
          currentPosition: () => null,
          stillWanted: () => true,
          onActiveChanged: badge.add,
          onLogged: logged.add,
          pendingRestores: [],
        );
        runners.add(runner);
        return runner;
      };
    }
  }

  int ms() => clock.now().difference(t0).inMilliseconds;
}

List<String> _timeline(
    {required bool withRunner,
    bool hybrid = false,
    int intervalMs = 30000,
    bool txSkipped = false,
    Duration? holdLease}) {
  late List<String> events;
  fakeAsync((async) {
    final s = _Scenario(async, withRunner: withRunner, intervalMs: intervalMs);
    s.gps.tooClose = txSkipped;
    s.radio.autoLease = holdLease ?? const Duration(milliseconds: 100);
    if (hybrid) {
      s.ping.enableAutoPing(hybridMode: true);
    } else {
      s.ping.enableAutoPing(passiveMode: true);
    }
    async.elapse(const Duration(seconds: 125));
    if (withRunner) {
      expect(s.radio.asks, isNotEmpty, reason: 'the runner really ran');
      expect(s.radio.overlaps, isEmpty);
    }
    events = List.of(s.conn.events);
    s.ping.forceDisableAutoPing();
    async.flushMicrotasks();
    s.ping.dispose();
    async.elapse(const Duration(seconds: 60));
  }, initialTime: DateTime(2026, 9, 26, 10));
  return events;
}

void main() {
  group('the schedule never moves', () {
    test('Passive: identical with no runner, and with a busy runner', () {
      final today = _timeline(withRunner: false);
      expect(today.where((e) => e.startsWith('disc@')),
          ['disc@0', 'disc@37000', 'disc@74000', 'disc@111000']);
      expect(_timeline(withRunner: true), today);
      // A runner that holds every lease for 3 s changes nothing either.
      expect(
          _timeline(withRunner: true, holdLease: const Duration(seconds: 3)),
          today);
    });

    test('Hybrid: identical with and without a runner, TX sent or skipped',
        () {
      for (final interval in [15000, 30000]) {
        for (final skipped in [false, true]) {
          final today = _timeline(
              withRunner: false,
              hybrid: true,
              intervalMs: interval,
              txSkipped: skipped);
          expect(today.where((e) => e.startsWith('disc@')).length,
              greaterThan(2), reason: today.join(' '));
          expect(
              _timeline(
                  withRunner: true,
                  hybrid: true,
                  intervalMs: interval,
                  txSkipped: skipped),
              today,
              reason: 'interval $interval, TX skipped $skipped');
        }
      }
    });

    test('a factory that returns null asks nothing and changes nothing', () {
      late List<String> events;
      fakeAsync((async) {
        final s = _Scenario(async, withRunner: false);
        var calls = 0;
        s.ping.scopeRunnerFactory = ({required hardStop, required cancel}) {
          calls++;
          return null;
        };
        s.ping.enableAutoPing(passiveMode: true);
        async.elapse(const Duration(seconds: 125));
        expect(calls, greaterThan(0));
        expect(s.ping.isScopeRunnerActive, isFalse);
        events = List.of(s.conn.events);
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
        s.ping.dispose();
      }, initialTime: DateTime(2026, 9, 26, 10));
      expect(events, _timeline(withRunner: false));
    });
  });

  group('hard stop', () {
    test('Passive: the next discovery is 30 s out, and so is the hard stop',
        () {
      fakeAsync((async) {
        final s = _Scenario(async);
        s.ping.enableAutoPing(passiveMode: true);
        async.elapse(const Duration(seconds: 8));
        final b = s.built.single;
        expect(b.earliest, b.at.add(const Duration(seconds: 30)));
        expect(b.hardStop, b.at.add(const Duration(seconds: 30)));
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
      });
    });

    void hybridAt15(bool txSkipped) {
      fakeAsync((async) {
        final s = _Scenario(async, intervalMs: 15000);
        s.gps.tooClose = txSkipped;
        s.ping.enableAutoPing(hybridMode: true);
        async.elapse(const Duration(seconds: 120));
        expect(s.built.length, greaterThan(2));
        final discs = [
          for (final e in s.conn.events)
            if (e.startsWith('disc@')) int.parse(e.substring(5)),
        ];
        for (final b in s.built) {
          // The TX leg waits 10 s, the discovery leg 8 s after it.
          expect(b.earliest, b.at.add(const Duration(seconds: 18)));
          expect(b.hardStop, b.earliest);
          final atMs = b.at.difference(s.t0).inMilliseconds;
          final hardMs = b.hardStop.difference(s.t0).inMilliseconds;
          final next = discs.firstWhere((d) => d > atMs, orElse: () => -1);
          if (next < 0) continue;
          expect(next, greaterThanOrEqualTo(hardMs),
              reason: 'no discovery before the hard stop');
          if (txSkipped) expect(next, hardMs, reason: 'exactly at it');
        }
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
      });
    }

    test('Hybrid at 15 s with the TX leg sent', () => hybridAt15(false));
    test('Hybrid at 15 s with the TX leg skipped', () => hybridAt15(true));

    test('the next discovery send cancels a runner mid-wait', () {
      fakeAsync((async) {
        final s = _Scenario(async);
        // One candidate whose wait outlasts the sweep would never be asked
        // (the hard stop refuses it), so hold the lease past the next send
        // instead.
        s.radio.autoLease = null;
        s.ping.enableAutoPing(passiveMode: true);
        async.elapse(const Duration(seconds: 8));
        expect(s.radio.leaseHeld, isTrue);
        final token = s.tokens.single;
        async.elapse(const Duration(seconds: 28));
        expect(token.isCancelled, isFalse);
        async.elapse(const Duration(seconds: 1)); // the 37 s discovery
        expect(s.conn.events.where((e) => e.startsWith('disc@')).length, 2);
        expect(token.isCancelled, isTrue);
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
      });
    });
  });

  group('candidates', () {
    test('repeaters only, strongest first, own replies carry their time', () {
      fakeAsync((async) {
        final s = _Scenario(async);
        s.conn.replies = [
          (keyFill: 0x11, type: DiscoveryConstants.nodeTypeRoom, own: true, rssi: -50),
          (keyFill: 0x22, type: DiscoveryConstants.nodeTypeRepeater, own: false, rssi: -60),
          (keyFill: 0x33, type: DiscoveryConstants.nodeTypeRepeater, own: true, rssi: -70),
        ];
        s.ping.enableAutoPing(passiveMode: true);
        async.elapse(const Duration(seconds: 20));
        expect(s.radio.asks.map((a) => a.key.substring(0, 2)), ['22', '33']);
        expect(s.radio.asks[0].answerWait, isNull,
            reason: 'another phone\'s discovery: no reply time');
        expect(s.radio.asks[1].answerWait,
            const Duration(milliseconds: 2300));
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
      });
    });

    test('DISC items not written within 2 s: nothing asked', () {
      fakeAsync((async) {
        final s = _Scenario(async);
        s.queue.discGate = Completer<void>();
        s.ping.enableAutoPing(passiveMode: true);
        async.elapse(const Duration(seconds: 20));
        expect(s.queue.discWrites, 2);
        expect(s.radio.asks, isEmpty);
        expect(s.ping.isScopeRunnerActive, isFalse);
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
      });
    });
  });

  group('cancellation', () {
    test('Stop with a Hybrid TX in flight while the runner holds a lease', () {
      fakeAsync((async) {
        final s = _Scenario(async);
        s.radio.autoLease = null; // held until the test says
        s.ping.enableAutoPing(hybridMode: true);
        async.elapse(const Duration(milliseconds: 32500)); // TX at 32 s
        expect(s.radio.leaseHeld, isTrue);
        expect(s.conn.events, contains('tx@32000'));
        expect(s.ping.pingInProgress, isTrue, reason: 'TX RX window open');
        final token = s.tokens.single;
        final accepted = s.ping.disableAutoPing();
        // Before the future is even awaited: already cancelled.
        expect(token.isCancelled, isTrue);
        expect(s.badge.last, isFalse);
        expect(s.ping.pendingDisable, isTrue, reason: 'the stop is parked');
        async.flushMicrotasks();
        expect(s.radio.leaseHeld, isFalse);
        var ok = false;
        accepted.then((v) => ok = v);
        async.elapse(const Duration(seconds: 6));
        expect(ok, isTrue);
        expect(s.ping.pendingDisable, isFalse, reason: 'the TX drained');
        expect(s.ping.autoPingEnabled, isFalse);
      });
    });

    test('Stop with a Hybrid TX in flight while the runner waits for an answer',
        () {
      fakeAsync((async) {
        final s = _Scenario(async);
        s.conn.replies = [
          (keyFill: 0x11, type: DiscoveryConstants.nodeTypeRepeater, own: true, rssi: -70),
        ];
        // A 5 s discovery reply gives a 7 s answer wait; a 23 s lease puts
        // that wait across the TX leg at 32 s.
        s.conn.replyDelay = const Duration(seconds: 5);
        s.radio.autoLease = const Duration(seconds: 23);
        s.ping.enableAutoPing(hybridMode: true);
        async.elapse(const Duration(milliseconds: 30500));
        expect(s.radio.inWait, isTrue);
        async.elapse(const Duration(milliseconds: 2000)); // TX at 32 s
        expect(s.conn.events, contains('tx@32000'));
        expect(s.ping.pingInProgress, isTrue);
        expect(s.radio.inWait, isTrue);
        final token = s.tokens.single;
        s.ping.disableAutoPing();
        expect(token.isCancelled, isTrue);
        expect(s.badge.last, isFalse);
        expect(s.ping.pendingDisable, isTrue);
        async.flushMicrotasks();
        expect(s.radio.inWait, isFalse);
        async.elapse(const Duration(seconds: 6));
        expect(s.ping.pendingDisable, isFalse);
        expect(s.ping.autoPingEnabled, isFalse);
      });
    });

    void stopsAtOnce(String name, void Function(_Scenario s) stop) {
      test('$name stops the runner at once', () {
        fakeAsync((async) {
          final s = _Scenario(async);
          s.radio.autoLease = null;
          s.ping.enableAutoPing(passiveMode: true);
          async.elapse(const Duration(seconds: 8));
          expect(s.radio.leaseHeld, isTrue);
          expect(s.ping.isScopeRunnerActive, isTrue);
          final asked = s.radio.asks.length;
          stop(s);
          expect(s.tokens.single.isCancelled, isTrue);
          expect(s.badge.last, isFalse);
          expect(s.ping.isScopeRunnerActive, isFalse);
          async.flushMicrotasks();
          expect(s.radio.leaseHeld, isFalse);
          async.elapse(const Duration(seconds: 30));
          expect(s.radio.asks.length, asked, reason: 'nothing more asked');
          s.ping.forceDisableAutoPing();
          async.flushMicrotasks();
        });
      });
    }

    stopsAtOnce('Stop', (s) => s.ping.disableAutoPing());
    stopsAtOnce('force disable', (s) => s.ping.forceDisableAutoPing());
    // The provider's events reach PingService through this (see
    // scope_lifecycle_test.dart for the events themselves).
    stopsAtOnce('cancelScopeRunner',
        (s) => s.ping.cancelScopeRunner('offline switch'));
    stopsAtOnce('dispose', (s) => s.ping.dispose());
  });

  // Smart Pinging holds a discovery back in a square that is already mapped
  // and banks it; the bank is released on the first fix in a clear square.
  // A runner's hard stop is the earliest the next discovery can go out, so
  // a banked discovery and a live runner meet only at the deferral instant,
  // before the runner's own hard-stop timer fires at that same moment. The
  // release below is made from exactly there (a microtask after the
  // deferral), the one moment the two can overlap.
  group('alongside Smart Pinging', () {
    /// Passive with Smart Pinging wired. The first discovery goes out clear
    /// and starts R1 at 7 s (hard stop 37 s); the 37 s attempt finds the
    /// square covered and banks. With [release], the bank is let go into a
    /// clear square from the deferral instant.
    ({_Scenario s, List<String> log, List<String> atWrite})
        passiveDeferredAt37(FakeAsync async,
            {required bool release,
            Duration? autoLease,
            Completer<ScopeRequestOutcome>? lateAnswer}) {
      final log = lease_support.captureScopeLog();
      final s = _Scenario(async, smartPing: true);
      s.radio.autoLease = autoLease;
      s.radio.lateAnswer = lateAnswer;
      final atWrite = <String>[];
      s.conn.onDiscoveryWrite = () {
        if (s.tokens.isEmpty) return; // the first discovery, before R1
        atWrite.add('${s.ms()}:cancelled=${s.tokens.first.isCancelled}'
            ':lease=${s.radio.leaseHeld}:asks=${s.radio.asks.length}');
      };
      s.onScheduled = (ms, reason) {
        if (reason != PingService.skipReasonRecentlyCovered) return;
        atWrite.add('deferred@${s.ms()}:cancelled=${s.tokens.first.isCancelled}');
        if (!release) return;
        scheduleMicrotask(() {
          s.coverage = RecentCoverage.clear;
          final released = s.ping.maybeSendBankedPing(_pos(46.0, -75.0));
          atWrite.add('released=$released');
        });
      };
      s.ping.enableAutoPing(passiveMode: true);
      async.elapse(const Duration(seconds: 8));
      expect(s.built, hasLength(1));
      expect(s.built.single.hardStop, s.t0.add(const Duration(seconds: 37)));
      s.coverage = RecentCoverage.covered;
      async.elapse(const Duration(milliseconds: 28999)); // 36.999 s
      return (s: s, log: log, atWrite: atWrite);
    }

    test('a banked discovery released while the runner waits for an answer '
        'cancels it before the write, and its late answer is ignored', () {
      fakeAsync((async) {
        final late = Completer<ScopeRequestOutcome>();
        final t = passiveDeferredAt37(async,
            release: true,
            autoLease: const Duration(milliseconds: 100),
            lateAnswer: late);
        final s = t.s;
        expect(s.radio.inWait, isTrue, reason: 'R1 is waiting for an answer');
        expect(s.ping.isScopeRunnerActive, isTrue);
        async.elapse(const Duration(milliseconds: 1)); // 37 s
        expect(t.atWrite, [
          'deferred@37000:cancelled=false',
          'released=true',
          startsWith('37000:cancelled=true'),
        ]);
        expect(
            t.log.where((l) => l.contains('Runner stopped: next discovery')),
            hasLength(1));
        expect(t.log.where((l) => l.contains('Runner stopped: hard stop')),
            isEmpty);
        // The answer lands after the cancel: the runner drops it.
        final loggedBefore = s.logged.length;
        late.complete(ScopeAnswered(
            Uint8List.fromList([0, 0, 0, 0, 0x41]), clock.now()));
        s.radio.lateAnswer = null;
        async.flushMicrotasks();
        expect(s.enqueued, 0);
        expect(s.logged.length, loggedBefore);
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 9, 26, 10));
    });

    test('the same release while the runner holds the lease: the discovery '
        'goes out once the lease is gone, and R1 writes nothing more', () {
      fakeAsync((async) {
        final t = passiveDeferredAt37(async, release: true);
        final s = t.s;
        expect(s.radio.leaseHeld, isTrue, reason: 'R1 holds the radio');
        final asksBefore = s.radio.asks.length;
        async.elapse(const Duration(milliseconds: 1)); // 37 s
        expect(t.atWrite, [
          'deferred@37000:cancelled=false',
          'released=true',
          '37000:cancelled=true:lease=false:asks=$asksBefore',
        ]);
        // R2 only starts once the released discovery's window closes at
        // 44 s; nothing is asked between the cancel and that.
        async.elapse(const Duration(milliseconds: 6900));
        expect(s.built, hasLength(1));
        expect(s.radio.asks.length, asksBefore);
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 9, 26, 10));
    });

    test('a deferred discovery does not cancel the runner, which ends at its '
        'own hard stop, and starts no new runner', () {
      fakeAsync((async) {
        // R1 holds the radio through the deferral.
        final t = passiveDeferredAt37(async, release: false);
        final s = t.s;
        expect(s.radio.leaseHeld, isTrue);
        async.elapse(const Duration(milliseconds: 1)); // 37 s
        expect(t.atWrite, ['deferred@37000:cancelled=false']);
        expect(s.tokens.single.isCancelled, isTrue);
        expect(s.ping.isScopeRunnerActive, isFalse);
        expect(t.log.where((l) => l.contains('Runner stopped: hard stop')),
            hasLength(1));
        expect(
            t.log.where((l) => l.contains('Runner stopped: next discovery')),
            isEmpty);
        // Still covered: the 67 s attempt defers too. No window, no runner.
        async.elapse(const Duration(seconds: 33));
        expect(s.conn.events.where((e) => e.startsWith('disc@')), ['disc@0']);
        expect(s.built, hasLength(1));
        expect(s.ping.bankedPing, BankedPingType.discovery);
        s.ping.forceDisableAutoPing();
        async.flushMicrotasks();
      }, initialTime: DateTime(2026, 9, 26, 10));
    });

    // The fakes above cannot show the radio's own lease gate, so this runs
    // the same order the release takes (cancel the runner, then write the
    // discovery) on a real connection, with the discovery already queued
    // behind a held lease.
    test('on a real connection, a discovery queued behind a lease goes out '
        'as soon as the cancel releases it, and no scope frame follows', () {
      lease_support.onScopeClock(lease_support.ScopeRadio.new, (async, radio, conn) {
        final cancel = ScopeCancelToken();
        final lease = lease_support.grant(async, conn, cancel: cancel)!;
        final granted = clock.now();
        var sent = false;
        conn.sendDiscoveryRequest().then((_) => sent = true);
        async.flushMicrotasks();
        expect(radio.commands, isNot(contains(CommandCodes.sendControlData)),
            reason: 'queued at the lease gate');
        async.elapse(const Duration(seconds: 1));
        expect(radio.commands, isNot(contains(CommandCodes.sendControlData)));

        final before = radio.commands.length;
        cancel.cancel();
        async.flushMicrotasks();
        expect(lease.active, isFalse);
        expect(radio.commands.skip(before), [CommandCodes.sendControlData]);
        expect(clock.now().difference(granted),
            lessThan(const Duration(seconds: 4)));

        // The cancelled lease writes nothing more.
        ScopeRequestOutcome? outcome;
        lease
            .requestScopes(lease_support.scopeKey(0xAB), Uint8List.fromList([1, 0]),
                answerWait: const Duration(seconds: 3),
                notAfter: clock.now().add(const Duration(seconds: 30)))
            .then((o) => outcome = o);
        radio.emit([ResponseCodes.ok]);
        async.elapse(const Duration(seconds: 5));
        expect(outcome, isNotNull);
        expect(radio.commands.skip(before), [CommandCodes.sendControlData]);
        expect(sent, isTrue);
      });
    });

    test('Hybrid with the TX leg deferred: the hard stop still lands before '
        'the next discovery goes out', () {
      for (final interval in [15000, 30000]) {
        fakeAsync((async) {
          final log = lease_support.captureScopeLog();
          final s = _Scenario(async, intervalMs: interval, smartPing: true);
          s.radio.autoLease = null; // R1 would hold the radio indefinitely
          final atWrite = <String>[];
          var txDeferred = 0;
          s.onScheduled = (ms, reason) {
            if (reason == PingService.skipReasonRecentlyCovered) {
              txDeferred++;
              // Only the TX leg is covered: the discovery leg goes out.
              s.coverage = RecentCoverage.clear;
            }
          };
          s.conn.onDiscoveryWrite = () {
            if (s.tokens.isEmpty) return;
            atWrite.add('${s.ms()}:cancelled=${s.tokens.first.isCancelled}'
                ':lease=${s.radio.leaseHeld}');
          };
          s.ping.enableAutoPing(hybridMode: true);
          // Until R1 is built, then cover the TX leg that follows.
          while (s.built.isEmpty) {
            async.elapse(const Duration(milliseconds: 100));
          }
          s.coverage = RecentCoverage.covered;
          final hardStop = s.built.single.hardStop;
          final earliest = s.built.single.earliest!;
          expect(hardStop.isAfter(earliest), isFalse,
              reason: 'interval $interval');
          async.elapse(earliest.difference(clock.now()) +
              const Duration(seconds: 1));
          expect(txDeferred, 1, reason: 'interval $interval');
          expect(s.conn.events.where((e) => e.startsWith('tx@')), isEmpty);
          final earliestMs = earliest.difference(s.t0).inMilliseconds;
          // The TX leg deferred with no RX window, so the discovery leg goes
          // out exactly at the earliest the runner was built against, and
          // the runner is already stopped when it does.
          expect(atWrite, ['$earliestMs:cancelled=true:lease=false'],
              reason: 'interval $interval');
          expect(log.where((l) => l.contains('Runner stopped: hard stop')),
              hasLength(1));
          expect(
              log.where((l) => l.contains('Runner stopped: next discovery')),
              isEmpty,
              reason: 'the hard stop, not the send, ended R1');
          s.ping.forceDisableAutoPing();
          async.flushMicrotasks();
        }, initialTime: DateTime(2026, 9, 26, 10));
      }
    });
  });
}
