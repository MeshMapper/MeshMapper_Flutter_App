import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/meshcore/scope_lease.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_discovery_rules.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_runner.dart';

import '../meshcore/scope_test_support.dart' as support;

// ---------------------------------------------------------------------------
// A fake radio: one lease at a time, a scripted answer per repeater, and a
// record of everything that would have gone on the air.
// ---------------------------------------------------------------------------

/// How one repeater behaves when asked.
class _Script {
  /// Time the lease stage takes (lookup, borrow, send, SENT, restore).
  final Duration leaseTime;

  /// The answer body arrives this long after SENT; null never answers.
  final Duration? answerAfter;

  /// The reply body, clock bytes included.
  final List<int> body;

  /// An outcome returned from inside the lease instead of a wait.
  final ScopeRequestOutcome? inLease;

  /// A record borrowed during the lease (left unrestored on cancel).
  final ContactRecord? borrow;

  /// The radio's est_timeout, for the fallback wait.
  final Duration est;

  const _Script({
    this.leaseTime = const Duration(milliseconds: 100),
    this.answerAfter,
    this.body = const [1, 2, 3, 4],
    this.inLease,
    this.borrow,
    this.est = const Duration(seconds: 2),
  });

  static _Script answers(String names,
          {Duration after = const Duration(milliseconds: 300)}) =>
      _Script(answerAfter: after, body: [1, 2, 3, 4, ...utf8.encode(names)]);
}

class _AskRecord {
  final String key;
  final Duration? answerWait;
  final DateTime notAfter;
  final DateTime at;
  Duration? wait;
  _AskRecord(this.key, this.answerWait, this.notAfter, this.at);
}

class _FakeRadio implements ScopeRadio {
  final Map<String, _Script> scripts = {};
  final List<_AskRecord> asks = [];

  /// Every frame the fake would have written, in order.
  final List<String> frames = [];
  final List<String> overlaps = [];
  bool refuse = false;
  Duration admissionDelay = Duration.zero;
  bool restoreOk = true;
  bool busy = false;
  _FakeLease? current;
  int acquires = 0;

  @override
  Future<ScopeLeaseHandle?> acquire(
      {required Duration admissionWait,
      required ScopeCancelToken cancel}) async {
    acquires++;
    if (busy) overlaps.add('acquire while busy');
    if (admissionDelay > Duration.zero) {
      await _race(admissionDelay, cancel);
    }
    if (refuse || cancel.isCancelled) return null;
    busy = true;
    return current = _FakeLease(this, cancel);
  }
}

/// Waits [d], or less when [cancel] fires. True when the wait ran out.
Future<bool> _race(Duration d, ScopeCancelToken cancel) {
  final done = Completer<bool>();
  final t = Timer(d, () {
    if (!done.isCompleted) done.complete(true);
  });
  cancel.whenCancelled.then((_) {
    t.cancel();
    if (!done.isCompleted) done.complete(false);
  });
  return done.future;
}

class _FakeLease implements ScopeLeaseHandle {
  final _FakeRadio radio;
  final ScopeCancelToken cancel;
  bool active = true;
  final List<ContactRecord> _unrestored = [];

  _FakeLease(this.radio, this.cancel);

  void _end() {
    if (!active) return;
    active = false;
    radio.busy = false;
  }

  @override
  List<ContactRecord> get unrestored => List.unmodifiable(_unrestored);

  @override
  Future<void> release() async => _end();

  @override
  Future<bool> restore(ContactRecord original) async {
    if (!active || cancel.isCancelled) return false;
    radio.frames.add('restore:${_hex(original.publicKey).substring(0, 8)}');
    if (!radio.restoreOk) {
      _unrestored.add(original);
      return false;
    }
    return true;
  }

  @override
  Future<ScopeRequestOutcome> requestScopes(Uint8List pubkey, Uint8List request,
      {required Duration? answerWait,
      required DateTime notAfter,
      void Function(Duration wait)? onSent}) async {
    final key = _hex(pubkey);
    if (!active || cancel.isCancelled) {
      _end();
      return const ScopeAborted();
    }
    final record = _AskRecord(key, answerWait, notAfter, clock.now());
    radio.asks.add(record);
    radio.frames.add('ask:${key.substring(0, 8)}');
    final s = radio.scripts[key] ?? const _Script();
    if (s.borrow != null) _unrestored.add(s.borrow!);
    final ran = await _race(s.leaseTime, cancel);
    if (!ran || !active) {
      _end();
      return ScopeAborted(
          restoreOwed: s.borrow != null, borrowedFrom: s.borrow);
    }
    if (s.inLease != null) {
      _end();
      return s.inLease!;
    }
    if (s.borrow != null) _unrestored.remove(s.borrow);
    var wait = answerWait ?? s.est + kScopeAnswerFallbackMargin;
    if (wait > kScopeAnswerWaitCap) wait = kScopeAnswerWaitCap;
    final sentAt = clock.now();
    var end = sentAt.add(wait);
    if (notAfter.isBefore(end)) end = notAfter;
    record.wait = wait;
    onSent?.call(wait);
    _end();
    // Answer wait, outside the lease.
    final remaining = end.difference(clock.now());
    final answerAfter = s.answerAfter;
    if (answerAfter != null && answerAfter <= remaining) {
      final ran2 = await _race(answerAfter, cancel);
      if (!ran2) return const ScopeAborted();
      return ScopeAnswered(Uint8List.fromList(s.body), clock.now());
    }
    final ran3 = await _race(remaining, cancel);
    if (!ran3) return const ScopeAborted();
    return const ScopeNoAnswer();
  }
}

String _hex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

String _key(int fill) =>
    List.filled(32, fill.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

ScopeCandidate _cand(int fill,
        {int rssi = -80,
        double snr = 5,
        Duration? reply = const Duration(milliseconds: 400),
        double lat = 45.0,
        double lon = -75.0}) =>
    (
      keyHex: _key(fill),
      repeaterId: _key(fill).substring(0, 2),
      lat: lat,
      lon: lon,
      localRssi: rssi,
      localSnr: snr,
      discoveryReplyAfter: reply,
    );

/// Everything a runner is built from, with knobs for the tests.
class _Harness {
  final _FakeRadio radio = _FakeRadio();
  final ScopeCancelToken cancel = ScopeCancelToken();
  late ScopeQueryCache cache = ScopeQueryCache.fromJson(null);
  final Map<String, dynamic> savedBudget = {};
  Map<String, dynamic>? savedCache;
  Completer<void>? budgetSaveGate;
  bool budgetSaveFails = false;
  late ScopeHourlyBudget budget = ScopeHourlyBudget(save: (json) async {
    if (budgetSaveGate != null) await budgetSaveGate!.future;
    if (budgetSaveFails) throw StateError('disk full');
    savedBudget
      ..clear()
      ..addAll(json);
  });
  final Map<String, ({bool onList, int? checkedAt})> server = {};
  bool serverListLoaded = true;
  final List<({ScopeAnswer answer, ScopePersistContext ctx})> enqueued = [];
  Future<bool> Function(ScopeAnswer, ScopePersistContext)? enqueueOverride;
  final List<bool> badge = [];
  final List<ScopeLogEntry> logged = [];
  ({double lat, double lon})? position = (lat: 45.0, lon: -75.0);
  bool wanted = true;
  int queueGeneration = 1;
  final List<ContactRecord> pendingRestores = [];
  final Set<String> knownNonContacts = {};
  bool cannotAskNonContacts = false;
  int cacheSaves = 0;

  int nowSec() => clock.now().millisecondsSinceEpoch ~/ 1000;

  ScopeRunner build({DateTime? hardStop, ScopeCancelToken? token}) {
    return ScopeRunner(
      radio: radio,
      cancel: token ?? cancel,
      hardStop: hardStop ?? clock.now().add(const Duration(seconds: 30)),
      refreshDays: () => 14,
      deviceKey: () => 'DEVICEKEY',
      sessionId: () => 'OTT-20260926-0001',
      queueGeneration: () => queueGeneration,
      serverInfo: (k) => serverListLoaded
          ? (server[k] ?? (onList: false, checkedAt: null))
          : (onList: false, checkedAt: null),
      cache: cache,
      budget: budget,
      enqueue: (a, ctx) {
        final o = enqueueOverride;
        if (o != null) return o(a, ctx);
        enqueued.add((answer: a, ctx: ctx));
        return Future.value(true);
      },
      onCacheStamped: () {
        cacheSaves++;
        savedCache = cache.toJson();
      },
      nowSec: nowSec,
      currentPosition: () => position,
      stillWanted: () => wanted,
      onActiveChanged: badge.add,
      onLogged: logged.add,
      pendingRestores: pendingRestores,
      knownNonContacts: knownNonContacts,
      cannotAskNonContacts: () => cannotAskNonContacts,
    );
  }
}

final DateTime _t0 = DateTime(2026, 9, 26, 10, 0, 0);

void _run(void Function(FakeAsync async, _Harness h) body) {
  fakeAsync((async) {
    final h = _Harness();
    body(async, h);
    async.elapse(const Duration(minutes: 2));
    async.flushMicrotasks();
  }, initialTime: _t0);
}

/// Runs [runner] to completion on the fake clock and returns once done.
bool Function() _start(FakeAsync async, ScopeRunner runner,
    List<ScopeCandidate> found,
    {Future<void>? discPersisted}) {
  var done = false;
  runner
      .run(found, discPersisted: discPersisted ?? Future<void>.value())
      .then((_) => done = true);
  async.flushMicrotasks();
  return () => done;
}

/// A point [meters] north of 45.0, -75.0.
({double lat, double lon}) _north(double meters) {
  // Search the latitude offset against the same distance function the runner
  // uses, so 299 m and 301 m are really on either side of 300 m.
  var lo = 0.0, hi = 0.01;
  for (var i = 0; i < 60; i++) {
    final mid = (lo + hi) / 2;
    final d = Geolocator.distanceBetween(45.0, -75.0, 45.0 + mid, -75.0);
    if (d < meters) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return (lat: 45.0 + hi, lon: -75.0);
}

void main() {
  group('choosing', () {
    test('at most 3 asks, one at a time, strongest RSSI first', () {
      _run((async, h) {
        final found = [
          _cand(0x11, rssi: -90),
          _cand(0x22, rssi: -60),
          _cand(0x33, rssi: -70),
          _cand(0x44, rssi: -100),
          _cand(0x55, rssi: -80),
        ];
        final done = _start(async, h.build(), found);
        async.elapse(const Duration(seconds: 30));
        expect(done(), isTrue);
        expect(h.radio.overlaps, isEmpty);
        expect(h.radio.asks.map((a) => a.key),
            [_key(0x22), _key(0x33), _key(0x55)]);
      });
    });

    test('SNR then key break RSSI ties', () {
      _run((async, h) {
        final found = [
          _cand(0x33, rssi: -70, snr: 2),
          _cand(0x22, rssi: -70, snr: 8),
          _cand(0x55, rssi: -70, snr: 2),
          _cand(0x11, rssi: -70, snr: 2),
        ];
        _start(async, h.build(), found);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks.map((a) => a.key),
            [_key(0x22), _key(0x11), _key(0x33)]);
      });
    });

    test('five found with the two strongest answered recently: 3rd to 5th asked',
        () {
      _run((async, h) {
        h.cache.recordAnswer(_key(0x11), h.nowSec() - 86400);
        h.server[_key(0x22)] = (onList: true, checkedAt: h.nowSec() - 3600);
        final found = [
          _cand(0x11, rssi: -50),
          _cand(0x22, rssi: -55),
          _cand(0x33, rssi: -60),
          _cand(0x44, rssi: -65),
          _cand(0x55, rssi: -70),
        ];
        _start(async, h.build(), found);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks.map((a) => a.key),
            [_key(0x33), _key(0x44), _key(0x55)]);
      });
    });

    test('due: fresh server stamp and phone answer skipped, ghost asked', () {
      _run((async, h) {
        h.server[_key(0x11)] = (onList: true, checkedAt: h.nowSec() - 60);
        h.cache.recordAnswer(_key(0x22), h.nowSec() - 60);
        h.server[_key(0x44)] =
            (onList: true, checkedAt: h.nowSec() - 30 * 86400);
        // 0x33 is a ghost: not on the server list at all.
        _start(async, h.build(), [
          _cand(0x11, rssi: -50),
          _cand(0x22, rssi: -51),
          _cand(0x33, rssi: -52),
          _cand(0x44, rssi: -53),
        ]);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks.map((a) => a.key), [_key(0x33), _key(0x44)]);
      });
    });

    test('a key whose answer is still being written is not asked', () {
      _run((async, h) {
        h.cache.pendingPersist.add(_key(0x11));
        _start(async, h.build(), [_cand(0x11, rssi: -50), _cand(0x22)]);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks.map((a) => a.key), [_key(0x22)]);
      });
    });

    test('pendingPersist at 32 stops the runner before asking', () {
      _run((async, h) {
        for (var i = 0; i < ScopeQueryCache.maxPendingPersist; i++) {
          h.cache.pendingPersist.add(_key(0x80 + i));
        }
        final done = _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(done(), isTrue);
        expect(h.radio.acquires, 0);
      });
    });

    test('DISC items not persisted within 2 s: the runner ends, nothing asked',
        () {
      _run((async, h) {
        final done = _start(async, h.build(), [_cand(0x11)],
            discPersisted: Completer<void>().future);
        async.elapse(const Duration(milliseconds: 1999));
        expect(done(), isFalse);
        async.elapse(const Duration(milliseconds: 2));
        expect(done(), isTrue);
        expect(h.radio.acquires, 0);
        expect(h.badge, isEmpty);
      });
    });

    test('a DISC write that failed ends the runner, nothing asked', () {
      _run((async, h) {
        final done = _start(async, h.build(), [_cand(0x11)],
            discPersisted: Future<void>.error(StateError('disk')));
        async.flushMicrotasks();
        expect(done(), isTrue);
        expect(h.radio.acquires, 0);
      });
    });

    test('DISC items persisted after 1 s: asks go ahead', () {
      _run((async, h) {
        final persisted = Completer<void>();
        _start(async, h.build(), [_cand(0x11)],
            discPersisted: persisted.future);
        async.elapse(const Duration(seconds: 1));
        expect(h.radio.acquires, 0);
        persisted.complete();
        async.elapse(const Duration(seconds: 10));
        expect(h.radio.asks, hasLength(1));
      });
    });
  });

  group('waits', () {
    test('each ask waits its own reply time plus 2 s, capped at 7 s', () {
      _run((async, h) {
        _start(async, h.build(), [
          _cand(0x11, rssi: -50, reply: const Duration(milliseconds: 400)),
          _cand(0x22, rssi: -60, reply: const Duration(seconds: 3)),
        ]);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks.map((a) => a.answerWait), [
          const Duration(milliseconds: 2400),
          const Duration(seconds: 5),
        ]);
      });
      _run((async, h) {
        _start(async, h.build(),
            [_cand(0x11, reply: const Duration(seconds: 6))]);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks.single.answerWait, const Duration(seconds: 7));
      });
    });

    test('unknown reply time passes no wait: the radio estimate plus 1 s', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] =
            const _Script(est: Duration(milliseconds: 1500));
        _start(async, h.build(), [_cand(0x11, reply: null)]);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks.single.answerWait, isNull);
        expect(h.radio.asks.single.wait, const Duration(milliseconds: 2500));
      });
    });

    test('an answer ends the wait early and the badge clears then', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] =
            _Script.answers('Ottawa', after: const Duration(milliseconds: 300));
        final done = _start(async, h.build(),
            [_cand(0x11, reply: const Duration(seconds: 6))]);
        expect(h.badge, [true]);
        async.elapse(const Duration(milliseconds: 399));
        expect(h.badge, [true]);
        async.elapse(const Duration(milliseconds: 2));
        expect(h.badge, [true, false]);
        async.flushMicrotasks();
        expect(done(), isTrue);
      });
    });
  });

  group('hard stop', () {
    test('an ask that would run past the hard stop is not started', () {
      _run((async, h) {
        // Admission 3 s + lease 4 s + 2.4 s wait = 9.4 s: the first fits
        // in 11 s, the second (due 2.5 s later, at 11.9 s) does not.
        final done = _start(
            async,
            h.build(hardStop: clock.now().add(const Duration(seconds: 11))),
            [_cand(0x11, rssi: -50), _cand(0x22, rssi: -60)]);
        async.elapse(const Duration(seconds: 11));
        expect(done(), isTrue);
        expect(h.radio.asks.map((a) => a.key), [_key(0x11)]);
      });
    });

    test('an unknown reply time reserves the full 7 s', () {
      _run((async, h) {
        final done = _start(
            async,
            h.build(hardStop: clock.now().add(const Duration(seconds: 13))),
            [_cand(0x11, reply: null)]);
        async.flushMicrotasks();
        expect(done(), isTrue);
        expect(h.radio.acquires, 0);
      });
      _run((async, h) {
        _start(
            async,
            h.build(hardStop: clock.now().add(const Duration(seconds: 14))),
            [_cand(0x11, reply: null)]);
        async.elapse(const Duration(seconds: 14));
        expect(h.radio.asks, hasLength(1));
      });
    });

    test('the hard-stop timer cancels a runner mid-ask', () {
      _run((async, h) {
        // A radio slower than any real lease, so the ask is still running
        // when the hard stop arrives.
        h.radio.scripts[_key(0x11)] =
            const _Script(leaseTime: Duration(seconds: 9));
        final done = _start(
            async,
            h.build(hardStop: clock.now().add(const Duration(seconds: 10))),
            [_cand(0x11)]);
        async.elapse(const Duration(milliseconds: 9999));
        expect(done(), isFalse);
        async.elapse(const Duration(seconds: 10));
        async.flushMicrotasks();
        expect(done(), isTrue);
        expect(h.cancel.isCancelled, isTrue);
        expect(h.badge.last, isFalse);
      });
    });

    test('the runner never outlives 30 s, whatever hard stop it is given', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] =
            const _Script(leaseTime: Duration(seconds: 40));
        final done = _start(
            async, h.build(hardStop: clock.now().add(const Duration(minutes: 5))),
            [_cand(0x11)]);
        async.elapse(const Duration(milliseconds: 29999));
        expect(done(), isFalse);
        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(done(), isTrue);
        expect(h.cancel.isCancelled, isTrue);
      });
    });
  });

  group('distance gate', () {
    void check(double meters, int expectedAsks) {
      _run((async, h) {
        final runner = h.build();
        _start(async, runner, [_cand(0x11, rssi: -50), _cand(0x22)]);
        // Move after the first ask has started.
        h.position = _north(meters);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks, hasLength(expectedAsks), reason: '$meters m');
      });
    }

    test('301 m before the 2nd ask stops the runner', () => check(301, 1));
    test('299 m continues', () => check(299, 2));
    test('a null position does not block', () {
      _run((async, h) {
        h.position = null;
        _start(async, h.build(), [_cand(0x11), _cand(0x22)]);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks, hasLength(2));
      });
    });
  });

  group('outcomes', () {
    test('an answer with names: one enqueue at the discovery point, stamped',
        () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa,*,west');
        h.position = (lat: 45.1, lon: -75.2);
        _start(async, h.build(), [_cand(0x11, lat: 45.1, lon: -75.2)]);
        async.elapse(const Duration(milliseconds: 100));
        final answerAt = clock.now().add(const Duration(milliseconds: 300));
        async.elapse(const Duration(seconds: 10));
        final e = h.enqueued.single;
        expect(e.answer.keyHex, _key(0x11));
        expect(e.answer.scopes, ['Ottawa', '*', 'west']);
        expect(e.answer.lat, 45.1);
        expect(e.answer.lon, -75.2);
        expect(e.answer.timestampSec, answerAt.millisecondsSinceEpoch ~/ 1000);
        expect(e.ctx.deviceKey, 'DEVICEKEY');
        expect(e.ctx.sessionId, 'OTT-20260926-0001');
        expect(e.ctx.queueGeneration, 1);
        expect(e.ctx.budgetHour, e.answer.timestampSec ~/ 3600);
        expect(h.cache[_key(0x11)]?.answeredAt, e.answer.timestampSec);
        expect(h.cacheSaves, 1);
        expect(h.logged.single.outcome, ScopeLogOutcome.answered);
        expect(h.logged.single.scopes, ['Ottawa', '*', 'west']);
        expect(h.logged.single.latitude, 45.1);
      });
    });

    test('an empty answer is enqueued as []', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] = _Script.answers('');
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.enqueued.single.answer.scopes, isEmpty);
        expect(h.cache[_key(0x11)], isNotNull);
      });
    });

    test('a timeout logs no response, stamps nothing, and holds the repeater',
        () {
      _run((async, h) {
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.logged.single.outcome, ScopeLogOutcome.noResponse);
        expect(h.enqueued, isEmpty);
        expect(h.cache[_key(0x11)], isNull);
        // A no-answer never stamps an answer, but it does start a hold: the
        // very next sweep must not re-ask it.
        expect(h.cache.heldUntil(_key(0x11)), isNotNull);
        final second = ScopeCancelToken();
        _start(async, h.build(token: second), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.radio.asks, hasLength(1),
            reason: 'held: the second sweep must not re-ask it');
      });
    });

    test('a first miss holds for 1 minute: not re-asked one second short, '
        'asked again exactly at the deadline when heard stronger', () {
      _run((async, h) {
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        final heldUntil = h.cache.heldUntil(_key(0x11));
        expect(heldUntil, isNotNull);

        // One second short of the deadline: still held, however strong. A
        // held sweep resolves on microtasks alone (nothing to ask), so this
        // must not itself advance the clock any further than the boundary
        // being tested.
        async.elapse(Duration(seconds: heldUntil! - h.nowSec() - 1));
        _start(async, h.build(token: ScopeCancelToken()),
            [_cand(0x11, rssi: -50)]);
        expect(h.radio.asks, hasLength(1),
            reason: 'one second short of the 1 minute deadline');

        // The deadline itself, heard 1 dB stronger: due again.
        async.elapse(const Duration(seconds: 1));
        expect(h.nowSec(), heldUntil);
        _start(async, h.build(token: ScopeCancelToken()),
            [_cand(0x11, rssi: -79)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.radio.asks, hasLength(2),
            reason: 'at the deadline and 1 dB stronger: due again');
      });
    });

    test('after the hold, a repeater heard no stronger waits out the full '
        '30 minutes from the miss', () {
      _run((async, h) {
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        final missAt = h.nowSec();
        final heldUntil = h.cache.heldUntil(_key(0x11))!;

        async.elapse(Duration(seconds: heldUntil - h.nowSec()));
        _start(async, h.build(token: ScopeCancelToken()),
            [_cand(0x11, rssi: -80)]);
        expect(h.radio.asks, hasLength(1),
            reason: 'no stronger: not worth another ask yet');

        // missAt is when the timeout landed; the hold was stamped a moment
        // before that, so this is at or just past 30 minutes from the miss.
        async.elapse(Duration(seconds: missAt + 30 * 60 - h.nowSec()));
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.radio.asks, hasLength(2),
            reason: '30 minutes after the miss the signal rule lapses');
      });
    });

    test('a second consecutive miss holds for 5 minutes', () {
      _run((async, h) {
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        final firstHeldUntil = h.cache.heldUntil(_key(0x11))!;

        // Wait out the first hold exactly, then miss again.
        async.elapse(Duration(seconds: firstHeldUntil - h.nowSec()));
        _start(async, h.build(token: ScopeCancelToken()),
            [_cand(0x11, rssi: -70)]);
        async.elapse(const Duration(seconds: 10));
        final secondHeldUntil = h.cache.heldUntil(_key(0x11))!;
        expect(h.radio.asks, hasLength(2));
        // Both asks take the same fixed lease + answer-wait time to miss, so
        // the gap between the two deadlines is ~5 minutes if the second
        // hold stepped up, ~1 minute if it did not.
        final gap = secondHeldUntil - firstHeldUntil;
        expect(gap, greaterThan(4 * 60),
            reason: 'the second hold must be 5 minutes, not another 1');
        expect(gap, lessThan(6 * 60));
      });
    });

    test('an answer clears the hold: the same repeater is due again at once '
        'once it finally answers', () {
      _run((async, h) {
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.cache.heldUntil(_key(0x11)), isNotNull);

        // Wait out the hold, then let the second, stronger ask answer.
        final heldUntil = h.cache.heldUntil(_key(0x11))!;
        async.elapse(Duration(seconds: heldUntil - h.nowSec()));
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(token: ScopeCancelToken()),
            [_cand(0x11, rssi: -70)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.cache[_key(0x11)], isNotNull);
        expect(h.cache.heldUntil(_key(0x11)), isNull,
            reason: 'an answer clears the hold');
      });
    });

    test('flooded, radio error, malformed and aborted outcomes never hold '
        'the repeater', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] = const _Script(inLease: ScopeFlooded());
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.cache.heldUntil(_key(0x11)), isNull);
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.radio.asks.where((a) => a.key == _key(0x11)).length, 2,
            reason: 'flooded never holds: asked again at once');

        h.radio.scripts[_key(0x22)] =
            const _Script(inLease: ScopeRadioError(3));
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x22)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.cache.heldUntil(_key(0x22)), isNull);
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x22)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.radio.asks.where((a) => a.key == _key(0x22)).length, 2,
            reason: 'a radio error never holds: asked again at once');

        h.radio.scripts[_key(0x33)] = const _Script(
            answerAfter: Duration(milliseconds: 300), body: [1, 2]);
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x33)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.cache.heldUntil(_key(0x33)), isNull);
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x33)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.radio.asks.where((a) => a.key == _key(0x33)).length, 2,
            reason: 'a malformed answer never holds: asked again at once');

        h.radio.scripts[_key(0x44)] = const _Script(inLease: ScopeAborted());
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x44)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.cache.heldUntil(_key(0x44)), isNull);
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x44)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.radio.asks.where((a) => a.key == _key(0x44)).length, 2,
            reason: 'an aborted ask never holds: asked again at once');
      });
    });

    test('a malformed answer logs unreadable, stamps nothing', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] = const _Script(
            answerAfter: Duration(milliseconds: 300), body: [1, 2]);
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.logged.single.outcome, ScopeLogOutcome.malformed);
        expect(h.enqueued, isEmpty);
        expect(h.cache[_key(0x11)], isNull);
      });
    });

    test('a malformed answer never parsed OK: it does NOT clear an existing '
        'hold', () {
      _run((async, h) {
        h.cache.recordNoAnswer(_key(0x11), h.nowSec());
        final heldBefore = h.cache.heldUntil(_key(0x11))!;
        // Wait out the hold so the repeater is due again for this ask;
        // otherwise it would never be chosen at all, malformed or not.
        async.elapse(Duration(seconds: heldBefore - h.nowSec()));
        h.radio.scripts[_key(0x11)] = const _Script(
            answerAfter: Duration(milliseconds: 300), body: [1, 2]);
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.logged.single.outcome, ScopeLogOutcome.malformed);
        expect(h.cache.heldUntil(_key(0x11)), heldBefore,
            reason: 'malformed never parsed, so the (now expired) hold is '
                'left exactly as it was');
      });
    });

    test('flood and radio error are logged and the next repeater is asked', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] = const _Script(inLease: ScopeFlooded());
        h.radio.scripts[_key(0x22)] =
            const _Script(inLease: ScopeRadioError(3));
        _start(async, h.build(),
            [_cand(0x11, rssi: -50), _cand(0x22, rssi: -60), _cand(0x33)]);
        async.elapse(const Duration(seconds: 30));
        expect(h.logged.map((e) => e.outcome), [
          ScopeLogOutcome.flooded,
          ScopeLogOutcome.radioError,
          ScopeLogOutcome.noResponse,
        ]);
        expect(h.cache[_key(0x11)], isNull);
        expect(h.cache[_key(0x22)], isNull);
      });
    });

    test('a local failure ends the runner, nothing logged or stamped', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] =
            const _Script(inLease: ScopeLocalFailure('hold_cap'));
        final done =
            _start(async, h.build(), [_cand(0x11, rssi: -50), _cand(0x22)]);
        async.elapse(const Duration(seconds: 30));
        expect(done(), isTrue);
        expect(h.radio.asks, hasLength(1));
        expect(h.logged, isEmpty);
        expect(h.badge, [true, false]);
      });
    });

    test('a refused lease ends the runner for this sweep', () {
      _run((async, h) {
        h.radio.refuse = true;
        final done =
            _start(async, h.build(), [_cand(0x11, rssi: -50), _cand(0x22)]);
        async.elapse(const Duration(seconds: 5));
        expect(done(), isTrue);
        expect(h.radio.acquires, 1);
        expect(h.logged, isEmpty);
        expect(h.badge, [true, false]);
      });
    });

    test('stillWanted false stops before the next ask', () {
      _run((async, h) {
        _start(async, h.build(), [_cand(0x11, rssi: -50), _cand(0x22)]);
        h.wanted = false;
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.asks, hasLength(1));
      });
    });

    test('run never throws: a throwing dependency is logged and ends it', () {
      _run((async, h) {
        final runner = ScopeRunner(
          radio: h.radio,
          cancel: h.cancel,
          hardStop: clock.now().add(const Duration(seconds: 30)),
          refreshDays: () => throw StateError('boom'),
          deviceKey: () => 'D',
          serverInfo: (_) => (onList: false, checkedAt: null),
          cache: h.cache,
          budget: h.budget,
          enqueue: (_, __) async => true,
          nowSec: h.nowSec,
          currentPosition: () => null,
          stillWanted: () => true,
          onActiveChanged: h.badge.add,
          onLogged: h.logged.add,
          pendingRestores: h.pendingRestores,
        );
        final done = _start(async, runner, [_cand(0x11)]);
        async.flushMicrotasks();
        expect(done(), isTrue);
      });
    });
  });

  group('budget', () {
    test('exhausted before asking: nothing asked', () {
      _run((async, h) {
        for (var i = 0; i < ScopeHourlyBudget.perHour; i++) {
          h.budget.tryConsume('DEVICEKEY', h.nowSec());
        }
        final done = _start(async, h.build(), [_cand(0x11)]);
        async.flushMicrotasks();
        expect(done(), isTrue);
        expect(h.radio.acquires, 0);
      });
    });

    test('full on arrival: withheld, not enqueued, not stamped', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(), [_cand(0x11)]);
        // Another answer fills the hour while this one is in flight.
        async.elapse(const Duration(milliseconds: 200));
        for (var i = 0; i < ScopeHourlyBudget.perHour; i++) {
          h.budget.tryConsume('DEVICEKEY', h.nowSec());
        }
        async.elapse(const Duration(seconds: 10));
        expect(h.logged.single.outcome, ScopeLogOutcome.withheldHourlyCap);
        expect(h.enqueued, isEmpty);
        expect(h.cache[_key(0x11)], isNull);
      });
    });

    test('full on arrival: withheld, but the parsed answer still clears an '
        'existing hold', () {
      _run((async, h) {
        h.cache.recordNoAnswer(_key(0x11), h.nowSec());
        final heldUntil = h.cache.heldUntil(_key(0x11))!;
        // Wait out the hold so the repeater is due again for this ask.
        async.elapse(Duration(seconds: heldUntil - h.nowSec()));
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x11)]);
        async.elapse(const Duration(milliseconds: 200));
        for (var i = 0; i < ScopeHourlyBudget.perHour; i++) {
          h.budget.tryConsume('DEVICEKEY', h.nowSec());
        }
        async.elapse(const Duration(seconds: 10));
        expect(h.logged.single.outcome, ScopeLogOutcome.withheldHourlyCap);
        expect(h.cache.heldUntil(_key(0x11)), isNull,
            reason: 'it answered and parsed OK, whatever the hourly cap did');
      });
    });

    test('a failed reservation write drops the answer, not stamped', () {
      _run((async, h) {
        h.budgetSaveFails = true;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.enqueued, isEmpty);
        expect(h.cache[_key(0x11)], isNull);
        expect(h.cache.pendingPersist, isEmpty);
      });
    });

    test('a failed reservation write drops the answer, but still clears an '
        'existing hold (the repeater proved it is reachable)', () {
      _run((async, h) {
        h.cache.recordNoAnswer(_key(0x11), h.nowSec());
        final heldUntil = h.cache.heldUntil(_key(0x11))!;
        // Wait out the hold so the repeater is due again for this ask.
        async.elapse(Duration(seconds: heldUntil - h.nowSec()));
        h.budgetSaveFails = true;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.enqueued, isEmpty);
        expect(h.cache[_key(0x11)], isNull,
            reason: 'the durable answer stamp still needs persistence');
        expect(h.cache.heldUntil(_key(0x11)), isNull,
            reason: 'a failed save must not leave the miss count in place');
      });
    });

    test('a stalled reservation write does not hold the runner', () {
      _run((async, h) {
        h.budgetSaveGate = Completer<void>();
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        final done =
            _start(async, h.build(), [_cand(0x11, rssi: -50), _cand(0x22)]);
        async.elapse(const Duration(seconds: 30));
        expect(done(), isTrue);
        expect(h.radio.asks, hasLength(2));
        expect(h.enqueued, isEmpty);
        expect(h.cache.pendingPersist, {_key(0x11)});
        h.budgetSaveGate!.complete();
        async.flushMicrotasks();
        expect(h.enqueued, hasLength(1));
        expect(h.cache.pendingPersist, isEmpty);
      });
    });
  });

  group('persistence', () {
    test('enqueue false: no stamp', () {
      _run((async, h) {
        h.enqueueOverride = (_, __) async => false;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.cache[_key(0x11)], isNull);
        expect(h.cacheSaves, 0);
        expect(h.cache.pendingPersist, isEmpty);
      });
    });

    test('enqueue false: still clears an existing hold', () {
      _run((async, h) {
        h.cache.recordNoAnswer(_key(0x11), h.nowSec());
        final heldUntil = h.cache.heldUntil(_key(0x11))!;
        // Wait out the hold so the repeater is due again for this ask.
        async.elapse(Duration(seconds: heldUntil - h.nowSec()));
        h.enqueueOverride = (_, __) async => false;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.cache[_key(0x11)], isNull);
        expect(h.cache.heldUntil(_key(0x11)), isNull,
            reason: 'a refused enqueue must not leave the miss count '
                'in place');
      });
    });

    test(
        'an enqueue that never completes: not stamped, not re-asked while '
        'pending, stamped once when it lands', () {
      _run((async, h) {
        final gate = Completer<bool>();
        h.enqueueOverride = (_, __) => gate.future;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.cache[_key(0x11)], isNull);
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.radio.asks, hasLength(1),
            reason: 'a pending answer keeps its repeater off the list');
        gate.complete(true);
        async.flushMicrotasks();
        expect(h.cache[_key(0x11)], isNotNull);
        expect(h.cacheSaves, 1);
      });
    });

    test('a queue cleared between the answer and the enqueue drops it', () {
      _run((async, h) {
        final hold = Completer<void>();
        h.budgetSaveGate = hold;
        h.enqueueOverride = (a, ctx) async =>
            ctx.queueGeneration == h.queueGeneration;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 1));
        h.queueGeneration++; // the queue is cleared
        hold.complete();
        async.elapse(const Duration(seconds: 10));
        expect(h.cache[_key(0x11)], isNull);
      });
    });

    test('a queue cleared during the answer wait: refused, nothing stamped',
        () {
      _run((async, h) {
        // The real queue refuses a stale generation.
        h.enqueueOverride = (a, ctx) async =>
            ctx.queueGeneration == h.queueGeneration;
        h.radio.scripts[_key(0x11)] =
            _Script.answers('Ottawa', after: const Duration(seconds: 1));
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(milliseconds: 500)); // in the wait
        h.queueGeneration++; // the queue (and the sweep's DISC) is cleared
        async.elapse(const Duration(seconds: 10));
        expect(h.logged.single.outcome, ScopeLogOutcome.answered);
        expect(h.cache[_key(0x11)], isNull,
            reason: 'the answer belongs to the sweep that was cleared');
        expect(h.cacheSaves, 0);
      });
    });

    test('every answer of a sweep carries the generation from its start', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] = _Script.answers('A');
        h.radio.scripts[_key(0x22)] = _Script.answers('B');
        _start(async, h.build(), [_cand(0x11, rssi: -50), _cand(0x22)]);
        async.elapse(const Duration(milliseconds: 50));
        h.queueGeneration = 7;
        async.elapse(const Duration(seconds: 20));
        expect(h.enqueued.map((e) => e.ctx.queueGeneration), [1, 1]);
      });
    });

    test(
        'an enqueue landing after a newer runner started stamps the cache and '
        'touches nothing else', () {
      _run((async, h) {
        final gate = Completer<bool>();
        h.enqueueOverride = (_, __) => gate.future;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        final first = h.build();
        _start(async, first, [_cand(0x11)]);
        async.elapse(const Duration(seconds: 1));
        first.cancel('next discovery');
        async.flushMicrotasks();
        final badgeBefore = List.of(h.badge);
        final token2 = ScopeCancelToken();
        final second = h.build(token: token2);
        _start(async, second, [_cand(0x22)]);
        expect(h.badge.last, isTrue);
        gate.complete(true);
        async.flushMicrotasks();
        expect(h.cache[_key(0x11)], isNotNull);
        expect(h.badge.last, isTrue,
            reason: 'the newer runner still owns the badge');
        expect(h.badge.length, badgeBefore.length + 1);
        expect(token2.isCancelled, isFalse);
      });
    });

    test('a late answer stamp survives a cache reload', () {
      _run((async, h) {
        final gate = Completer<bool>();
        h.enqueueOverride = (_, __) => gate.future;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        final done = _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(done(), isTrue);
        gate.complete(true);
        async.flushMicrotasks();
        final reloaded = ScopeQueryCache.fromJson(h.savedCache);
        expect(
            isScopeQueryDue(
                onServerList: false,
                serverCheckedAt: null,
                phone: reloaded[_key(0x11)],
                persistPending: false,
                nowSec: h.nowSec(),
                refreshDays: 14),
            isFalse);
      });
    });
  });

  group('cancellation', () {
    test('cancel mid-lease: nothing more written, badge clears, record kept',
        () {
      _run((async, h) {
        final borrowed = ContactRecord.newRepeater(
            publicKey: Uint8List.fromList(List.filled(32, 0x11)),
            name: 'R',
            lat: 1,
            lon: 2,
            nowSecs: 5);
        h.radio.scripts[_key(0x11)] = _Script(
            leaseTime: const Duration(seconds: 2), borrow: borrowed);
        final runner = h.build();
        final done =
            _start(async, runner, [_cand(0x11, rssi: -50), _cand(0x22)]);
        async.elapse(const Duration(milliseconds: 500));
        runner.cancel('stop');
        expect(h.badge.last, isFalse, reason: 'cleared at once');
        async.flushMicrotasks();
        expect(done(), isTrue);
        expect(h.radio.busy, isFalse);
        final framesAtCancel = List.of(h.radio.frames);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.frames, framesAtCancel);
        expect(h.pendingRestores.single.publicKey, borrowed.publicKey);

        // The next runner on the same connection restores it first.
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x33)]);
        async.elapse(const Duration(seconds: 30));
        expect(h.radio.frames.sublist(framesAtCancel.length),
            ['restore:11111111', 'ask:33333333']);
        expect(h.pendingRestores, isEmpty);
      });
    });

    test('cancel mid-wait: the late answer is ignored', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] =
            _Script.answers('Ottawa', after: const Duration(seconds: 3));
        final runner = h.build();
        _start(async, runner,
            [_cand(0x11, reply: const Duration(seconds: 5))]);
        async.elapse(const Duration(seconds: 1));
        runner.cancel('next discovery');
        async.elapse(const Duration(seconds: 10));
        expect(h.enqueued, isEmpty);
        expect(h.logged, isEmpty);
        expect(h.badge, [true, false]);
      });
    });

    test('a cancelled runner never flips a newer runner\'s badge', () {
      _run((async, h) {
        final first = h.build();
        var current = first;
        first.isCurrent = () => identical(current, first);
        _start(async, first, [_cand(0x11, reply: const Duration(seconds: 5))]);
        async.elapse(const Duration(milliseconds: 500));
        first.cancel('next discovery');
        final second = h.build(token: ScopeCancelToken());
        current = second;
        second.isCurrent = () => identical(current, second);
        _start(async, second, [_cand(0x22, reply: const Duration(seconds: 5))]);
        final badgeAfterSecondStart = List.of(h.badge);
        expect(badgeAfterSecondStart.last, isTrue);
        async.elapse(const Duration(milliseconds: 500));
        expect(h.badge, badgeAfterSecondStart);
      });
    });

    test('an already cancelled runner asks nothing', () {
      _run((async, h) {
        final runner = h.build();
        runner.cancel('stop');
        final done = _start(async, runner, [_cand(0x11)]);
        async.flushMicrotasks();
        expect(done(), isTrue);
        expect(h.radio.acquires, 0);
        expect(h.badge, isEmpty);
      });
    });
  });

  group('contact table full', () {
    test('a non-contact table-full radio error is logged distinctly and '
        'remembered', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] = const _Script(
            inLease: ScopeRadioError(3, nonContactTableFull: true));
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.logged.single.outcome, ScopeLogOutcome.radioContactsFull);
      });
    });

    test('a saved contact\'s table-full radio error is logged as the '
        'ordinary radio error', () {
      _run((async, h) {
        h.radio.scripts[_key(0x11)] =
            const _Script(inLease: ScopeRadioError(3));
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.logged.single.outcome, ScopeLogOutcome.radioError);
      });
    });

    test('with the flag set, a known non-contact is skipped with no lease',
        () {
      _run((async, h) {
        h.cannotAskNonContacts = true;
        h.knownNonContacts.add(_key(0x11));
        final done = _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(done(), isTrue);
        expect(h.radio.acquires, 0);
        expect(h.radio.frames, isEmpty);
        expect(h.logged, isEmpty);
      });
    });

    test('with the flag set, an unknown repeater is still looked up, and a '
        'refusal is remembered but never logged', () {
      _run((async, h) {
        h.cannotAskNonContacts = true;
        h.radio.scripts[_key(0x11)] =
            const _Script(inLease: ScopeNonContactRefused());
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.radio.acquires, 1, reason: 'the lookup is still taken');
        expect(h.logged, isEmpty,
            reason: 'never shown in the log tab, debug log only');
        expect(h.knownNonContacts, contains(_key(0x11)));

        // The next sweep skips it without a lease.
        final acquiresBefore = h.radio.acquires;
        _start(async, h.build(token: ScopeCancelToken()), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 5));
        expect(h.radio.acquires, acquiresBefore,
            reason: 'now known, so no lease this time');
      });
    });

    test('the flag alone (no known-non-contact entry) does not block an ask',
        () {
      _run((async, h) {
        h.cannotAskNonContacts = true;
        h.radio.scripts[_key(0x11)] = _Script.answers('Ottawa');
        _start(async, h.build(), [_cand(0x11)]);
        async.elapse(const Duration(seconds: 10));
        expect(h.enqueued.single.answer.scopes, ['Ottawa']);
      });
    });

    test(
        'three blocked strongest repeaters do not starve a weaker saved '
        'contact out of the top 3', () {
      _run((async, h) {
        h.cannotAskNonContacts = true;
        h.knownNonContacts.addAll([_key(0x11), _key(0x22), _key(0x33)]);
        h.radio.scripts[_key(0x44)] = _Script.answers('Ottawa');
        final found = [
          _cand(0x11, rssi: -50),
          _cand(0x22, rssi: -55),
          _cand(0x33, rssi: -60),
          _cand(0x44, rssi: -65),
        ];
        _start(async, h.build(), found);
        async.elapse(const Duration(seconds: 30));
        // The three known non-contacts are filtered out before the top-3
        // cut, not skipped after it, so the 4th (weaker but askable)
        // repeater gets a slot instead of being starved forever.
        expect(h.radio.asks.map((a) => a.key), [_key(0x44)]);
        expect(h.radio.acquires, 1);
      });
    });
  });

  group('on a real connection', () {
    ScopeRunner realRunner(_Harness h, MeshCoreConnection conn,
            {ScopeCancelToken? token}) =>
        ScopeRunner(
          radio: MeshCoreScopeRadio(conn),
          cancel: token ?? h.cancel,
          hardStop: clock.now().add(const Duration(seconds: 30)),
          refreshDays: () => 14,
          deviceKey: () => 'DEVICEKEY',
          serverInfo: (_) => (onList: false, checkedAt: null),
          cache: h.cache,
          budget: h.budget,
          enqueue: (a, ctx) async {
            h.enqueued.add((answer: a, ctx: ctx));
            return true;
          },
          nowSec: h.nowSec,
          currentPosition: () => null,
          stillWanted: () => true,
          onActiveChanged: h.badge.add,
          onLogged: h.logged.add,
          pendingRestores: h.pendingRestores,
        );

    test('a TX issued during the lease goes out when it releases, within 4 s',
        () {
      support.onScopeClock(support.ScopeRadio.new, (async, radio, conn) {
        final h = _Harness();
        realRunner(h, conn)
            .run([_cand(0x11)], discPersisted: Future<void>.value());
        async.flushMicrotasks();
        expect(conn.isScopeLeaseActive, isTrue);
        conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) {});
        // The radio never answers the lookup: the lease runs out at 4 s.
        async.elapse(const Duration(milliseconds: 3999));
        expect(radio.commands, isNot(contains(CommandCodes.sendChannelTxtMsg)));
        async.elapse(const Duration(milliseconds: 1));
        expect(radio.commands, contains(CommandCodes.sendChannelTxtMsg));
        async.elapse(const Duration(seconds: 30));
      });
    });

    test('a TX and a discovery during the answer wait go out at once', () {
      support.onScopeClock(support.ScopeRadio.new, (async, radio, conn) {
        final h = _Harness();
        realRunner(h, conn).run([_cand(0x11, reply: null)],
            discPersisted: Future<void>.value());
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit(support.sentFrame(est: 1500));
        async.flushMicrotasks();
        expect(conn.isScopeLeaseActive, isFalse);
        expect(conn.isScopeListenActive, isTrue);
        final before = radio.writes.length;
        conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) {});
        conn.sendDiscoveryRequest();
        async.flushMicrotasks();
        expect(radio.commands.sublist(before),
            [CommandCodes.sendChannelTxtMsg, CommandCodes.sendControlData]);
        // Unknown reply time: est 1.5 s + 1 s.
        async.elapse(const Duration(milliseconds: 2499));
        expect(h.logged, isEmpty);
        async.elapse(const Duration(milliseconds: 2));
        expect(h.logged.single.outcome, ScopeLogOutcome.noResponse);
        async.elapse(const Duration(seconds: 30));
      });
    });

    test('cancel during the lease releases the radio and writes nothing more',
        () {
      support.onScopeClock(support.ScopeRadio.new, (async, radio, conn) {
        final h = _Harness();
        final runner = realRunner(h, conn);
        runner.run([_cand(0x11)], discPersisted: Future<void>.value());
        async.flushMicrotasks();
        expect(conn.isScopeLeaseActive, isTrue);
        final written = radio.writes.length;
        runner.cancel('stop');
        expect(conn.isScopeLeaseActive, isFalse, reason: 'released at once');
        expect(h.badge.last, isFalse);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.elapse(const Duration(seconds: 30));
        expect(radio.writes.length, written);
      });
    });

    test('cancel during the answer wait frees the slot', () {
      support.onScopeClock(support.ScopeRadio.new, (async, radio, conn) {
        final h = _Harness();
        final runner = realRunner(h, conn);
        runner.run([_cand(0x11)], discPersisted: Future<void>.value());
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit(support.sentFrame());
        async.flushMicrotasks();
        expect(conn.isScopeListenActive, isTrue);
        runner.cancel('stop');
        async.flushMicrotasks();
        expect(conn.isScopeListenActive, isFalse);
        expect(conn.hasPendingAdminCommand, isFalse);
        radio.emit(support.answerPush(body: [1, 2, 3, 4, 0x41]));
        async.elapse(const Duration(seconds: 30));
        expect(h.enqueued, isEmpty);
      });
    });
  });
}
