import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/scope_discovery/scope_discovery_rules.dart';

void main() {
  final keyA = 'AB' * 32;
  final keyB = 'CD' * 32;

  group('isScopeQueryDue', () {
    const days = 14;
    const refreshSec = days * 86400;
    const now = 2000000000;

    test('persistPending true is never due, even when both rules pass', () {
      final due = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: null,
        phone: null,
        persistPending: true,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isFalse);
    });

    test('server fresh, phone fresh: not due', () {
      final due = isScopeQueryDue(
        onServerList: true,
        serverCheckedAt: now - 10,
        phone: const ScopeCacheEntry(answeredAt: now - 10),
        persistPending: false,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isFalse);
    });

    test('server stale (Rule 1 true), phone stale (Rule 2 true): due', () {
      final due = isScopeQueryDue(
        onServerList: true,
        serverCheckedAt: now - refreshSec - 1,
        phone: const ScopeCacheEntry(answeredAt: now - refreshSec - 1),
        persistPending: false,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isTrue);
    });

    test('server never checked (null): Rule 1 true regardless of phone', () {
      final due = isScopeQueryDue(
        onServerList: true,
        serverCheckedAt: null,
        phone: const ScopeCacheEntry(answeredAt: now - refreshSec - 1),
        persistPending: false,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isTrue);
    });

    test('not on the server list at all: Rule 1 true regardless of serverCheckedAt', () {
      final due = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: now - 10,
        phone: const ScopeCacheEntry(answeredAt: now - refreshSec - 1),
        persistPending: false,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isTrue);
    });

    test('server stale but phone answered fresh: Rule 2 blocks, not due', () {
      final due = isScopeQueryDue(
        onServerList: true,
        serverCheckedAt: now - refreshSec - 1,
        phone: const ScopeCacheEntry(answeredAt: now - 10),
        persistPending: false,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isFalse);
    });

    test('server fresh but phone has no answer: Rule 1 blocks, not due', () {
      final due = isScopeQueryDue(
        onServerList: true,
        serverCheckedAt: now - 10,
        phone: null,
        persistPending: false,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isFalse);
    });

    test('a non-answer leaves no phone entry, so it is due again at once '
        '(so long as the server rule also agrees)', () {
      final due = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: null,
        phone: const ScopeCacheEntry(answeredAt: null),
        persistPending: false,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isTrue);
    });

    test('interval 7 vs 14 both honoured on the boundary', () {
      const answeredAt = now - 8 * 86400; // 8 days ago
      final dueAt7 = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: null,
        phone: const ScopeCacheEntry(answeredAt: answeredAt),
        persistPending: false,
        nowSec: now,
        refreshDays: 7,
      );
      final dueAt14 = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: null,
        phone: const ScopeCacheEntry(answeredAt: answeredAt),
        persistPending: false,
        nowSec: now,
        refreshDays: 14,
      );
      expect(dueAt7, isTrue, reason: '8 days >= 7 day interval');
      expect(dueAt14, isFalse, reason: '8 days < 14 day interval');
    });

    test('heldUntil in the future: not due, even when both rules pass', () {
      final due = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: null,
        phone: null,
        persistPending: false,
        nowSec: now,
        refreshDays: days,
        heldUntil: now + 1,
      );
      expect(due, isFalse);
    });

    test('heldUntil exactly now: due (the hold has just expired)', () {
      final due = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: null,
        phone: null,
        persistPending: false,
        nowSec: now,
        refreshDays: days,
        heldUntil: now,
      );
      expect(due, isTrue);
    });

    test('heldUntil in the past: due, same as no hold at all', () {
      final due = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: null,
        phone: null,
        persistPending: false,
        nowSec: now,
        refreshDays: days,
        heldUntil: now - 1,
      );
      expect(due, isTrue);
    });

    test('heldUntil null: unaffected (no hold at all)', () {
      final due = isScopeQueryDue(
        onServerList: false,
        serverCheckedAt: null,
        phone: null,
        persistPending: false,
        nowSec: now,
        refreshDays: days,
      );
      expect(due, isTrue);
    });
  });

  group('ScopeQueryCache', () {
    const now = 2000000000;

    test('round trip keeps the answer stamp', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordAnswer(keyA, now);
      final restored = ScopeQueryCache.fromJson(cache.toJson());
      expect(restored[keyA]?.answeredAt, now);
    });

    test('operator[] and recordAnswer normalize the key (lower case, prefix)', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordAnswer(keyA.toLowerCase(), now);
      expect(cache[keyA]?.answeredAt, now);
      expect(cache['0x$keyA']?.answeredAt, now);
    });

    test('an unrecognized key never lands in the cache', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordAnswer('not-a-key', now);
      expect(cache.toJson(), isEmpty);
      expect(cache['not-a-key'], isNull);
    });

    test('a repeater never recorded has no entry (due again at once)', () {
      final cache = ScopeQueryCache.fromJson(null);
      expect(cache[keyA], isNull);
    });

    test('fromJson tolerates junk: non-map root, bad key, bad value', () {
      expect(ScopeQueryCache.fromJson(null).toJson(), isEmpty);
      final cache = ScopeQueryCache.fromJson({
        'not-a-key': {'answeredAt': now},
        keyA: 'not-a-map',
        keyB: {'answeredAt': 'not-an-int'},
      });
      expect(cache.toJson(), isEmpty);
    });

    test('pendingPersist is memory-only and does not survive a round trip', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordAnswer(keyA, now);
      cache.pendingPersist.add(keyA);
      final json = cache.toJson();
      expect(json.values.any((v) => v.toString().contains('pendingPersist')),
          isFalse);
      final restored = ScopeQueryCache.fromJson(json);
      expect(restored.pendingPersist, isEmpty);
      // The stamp itself did survive; only the in-flight marker did not.
      expect(restored[keyA]?.answeredAt, now);
    });

    test('prune keeps a 500-day-old answer under a 1000-day interval', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordAnswer(keyA, now - 500 * 86400);
      cache.prune(nowSec: now, refreshDays: 1000);
      expect(cache[keyA], isNotNull);
    });

    test('prune drops that same answer under a 400-day interval', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordAnswer(keyA, now - 500 * 86400);
      cache.prune(nowSec: now, refreshDays: 400);
      expect(cache[keyA], isNull);
    });

    test('prune under cache pressure evicts exactly the oldest answer', () {
      final cache = ScopeQueryCache.fromJson(null);
      // 20001 entries, none stale under the interval used below, spaced one
      // second apart so there is exactly one oldest.
      for (var i = 0; i < ScopeQueryCache.maxEntries + 1; i++) {
        final key = i.toRadixString(16).padLeft(64, '0').toUpperCase();
        cache.recordAnswer(key, now - i);
      }
      final oldestKey =
          ScopeQueryCache.maxEntries.toRadixString(16).padLeft(64, '0').toUpperCase();
      expect(cache[oldestKey], isNotNull);
      cache.prune(nowSec: now, refreshDays: 36500); // interval keeps all
      expect(cache.toJson().length, ScopeQueryCache.maxEntries);
      expect(cache[oldestKey], isNull, reason: 'the single oldest answer is evicted');
    });

    test('a repeater that has never missed has no hold', () {
      final cache = ScopeQueryCache.fromJson(null);
      expect(cache.heldUntil(keyA), isNull);
    });

    test('recordNoAnswer holds for 1 minute on the first miss', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer(keyA, now);
      expect(cache.heldUntil(keyA), now + 60);
    });

    test('consecutive misses hold for 1, 5, 10, 20, then 30 minutes', () {
      final cache = ScopeQueryCache.fromJson(null);
      const expected = [1, 5, 10, 20, 30, 30, 30];
      for (var i = 0; i < expected.length; i++) {
        cache.recordNoAnswer(keyA, now + i);
        expect(cache.heldUntil(keyA), now + i + expected[i] * 60,
            reason: 'miss #${i + 1}');
      }
    });

    test('after a miss, a retry needs a stronger signal until 30 minutes '
        'have passed', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer(keyA, now, rssi: -100);
      bool weak(int t, int rssi) =>
          cache.awaitingStrongerSignal(keyA, nowSec: t, rssi: rssi);
      expect(weak(now + 60, -100), isTrue, reason: 'same signal');
      expect(weak(now + 60, -101), isTrue, reason: 'weaker');
      expect(weak(now + 60, -99), isFalse, reason: '1 dB stronger');
      expect(weak(now + 30 * 60 - 1, -100), isTrue);
      expect(weak(now + 30 * 60, -100), isFalse,
          reason: '30 minutes after the miss the rule lapses');
    });

    test('the signal rule tracks the latest miss', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer(keyA, now, rssi: -100);
      cache.recordNoAnswer(keyA, now + 60, rssi: -90);
      expect(cache.awaitingStrongerSignal(keyA, nowSec: now + 400, rssi: -90),
          isTrue,
          reason: 'measured against -90, the latest miss');
      expect(cache.awaitingStrongerSignal(keyA, nowSec: now + 400, rssi: -89),
          isFalse);
    });

    test('no signal rule without a miss RSSI, a hold, or after an answer',
        () {
      final cache = ScopeQueryCache.fromJson(null);
      expect(cache.awaitingStrongerSignal(keyA, nowSec: now, rssi: -100),
          isFalse, reason: 'never missed');
      cache.recordNoAnswer(keyA, now);
      expect(cache.awaitingStrongerSignal(keyA, nowSec: now + 60, rssi: -100),
          isFalse, reason: 'the miss carried no RSSI');
      cache.recordNoAnswer(keyA, now, rssi: -100);
      cache.clearHold(keyA);
      expect(cache.awaitingStrongerSignal(keyA, nowSec: now + 60, rssi: -100),
          isFalse, reason: 'an answer cleared the hold');
    });

    test('an answer clears the hold and resets the miss count', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer(keyA, now);
      cache.recordNoAnswer(keyA, now + 1);
      expect(cache.heldUntil(keyA), isNotNull);
      cache.recordAnswer(keyA, now + 2);
      expect(cache.heldUntil(keyA), isNull);
      // The miss count reset too: the next miss holds for the first step's
      // 1 minute again, not the third step's 10.
      cache.recordNoAnswer(keyA, now + 3);
      expect(cache.heldUntil(keyA), now + 3 + 60);
    });

    test('recordNoAnswer on an unrecognized key is a no-op', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer('not-a-key', now);
      expect(cache.toJson(), isEmpty);
      expect(cache.heldUntil('not-a-key'), isNull);
    });

    test('a hold does not survive a cache reload (memory only)', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer(keyA, now);
      expect(cache.heldUntil(keyA), isNotNull);
      final reloaded = ScopeQueryCache.fromJson(cache.toJson());
      expect(reloaded.heldUntil(keyA), isNull);
    });

    test('clearHold clears an existing hold without touching the answer '
        'stamp', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer(keyA, now);
      cache.recordNoAnswer(keyA, now + 1);
      expect(cache.heldUntil(keyA), isNotNull);
      cache.clearHold(keyA);
      expect(cache.heldUntil(keyA), isNull);
      // No answer stamp was ever recorded (a real answer that failed to
      // persist does not get a durable stamp), and clearHold must not
      // invent one.
      expect(cache[keyA], isNull);
    });

    test('clearHold resets the miss count too: the next miss is the first '
        'step again', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer(keyA, now);
      cache.recordNoAnswer(keyA, now + 1);
      cache.clearHold(keyA);
      cache.recordNoAnswer(keyA, now + 2);
      expect(cache.heldUntil(keyA), now + 2 + 60);
    });

    test('clearHold on a key with no hold is a no-op', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.clearHold(keyA);
      expect(cache.heldUntil(keyA), isNull);
    });

    test('clearHold on an unrecognized key is a no-op', () {
      final cache = ScopeQueryCache.fromJson(null);
      cache.recordNoAnswer(keyA, now);
      cache.clearHold('not-a-key');
      expect(cache.heldUntil(keyA), isNotNull,
          reason: 'an unrecognized key must not touch keyA');
    });
  });

  group('ScopeHourlyBudget', () {
    const hour = 555;
    const now = hour * 3600 + 100;

    Future<void> noopSave(Map<String, dynamic> json) async {}

    test('allows 60 in one device-hour and refuses the 61st', () {
      final budget = ScopeHourlyBudget(save: noopSave);
      for (var i = 0; i < 60; i++) {
        expect(budget.tryConsume(keyA, now), isTrue, reason: 'ask $i');
      }
      expect(budget.tryConsume(keyA, now), isFalse);
      expect(budget.canAsk(keyA, now), isFalse);
    });

    test('a new hour starts fresh', () {
      final budget = ScopeHourlyBudget(save: noopSave);
      for (var i = 0; i < 60; i++) {
        budget.tryConsume(keyA, now);
      }
      expect(budget.tryConsume(keyA, now + 3600), isTrue);
    });

    test('the same device is still capped under a new session id '
        '(deviceKey is the radio key, not the session)', () {
      final budget = ScopeHourlyBudget(save: noopSave);
      for (var i = 0; i < 60; i++) {
        budget.tryConsume(keyA, now);
      }
      // A "new session" changes nothing the budget sees: deviceKey is the
      // radio's own public key, so the same key stays capped.
      expect(budget.tryConsume(keyA, now), isFalse);
    });

    test('a different device starts fresh', () {
      final budget = ScopeHourlyBudget(save: noopSave);
      for (var i = 0; i < 60; i++) {
        budget.tryConsume(keyA, now);
      }
      expect(budget.tryConsume(keyB, now), isTrue);
    });

    test('tryConsume in a full hour returns false', () {
      final budget = ScopeHourlyBudget(save: noopSave);
      for (var i = 0; i < 60; i++) {
        budget.tryConsume(keyA, now);
      }
      expect(budget.tryConsume(keyA, now), isFalse);
    });

    test('tryConsume reserves synchronously and never waits on a stalled '
        'persistReservation write', () {
      final release = Completer<void>();
      final stalled = ScopeHourlyBudget(save: (json) async {
        await release.future;
      });
      // Reserve, then kick off a persist that will hang.
      expect(stalled.tryConsume(keyA, now), isTrue);
      var finished = false;
      // ignore: unawaited_futures
      stalled.persistReservation(keyA, now ~/ 3600).then((_) => finished = true);
      // The reservation itself is immediate: a second, different bucket can
      // be consumed right away without waiting on the hung save.
      expect(stalled.tryConsume(keyB, now), isTrue);
      expect(finished, isFalse);
      release.complete();
    });

    test('a failed reservation write drops the answer but keeps the count', () async {
      final budget = ScopeHourlyBudget(save: (json) async {
        throw Exception('disk full');
      });
      expect(budget.tryConsume(keyA, now), isTrue);
      final ok = await budget.persistReservation(keyA, now ~/ 3600);
      expect(ok, isFalse);
      // The in-memory reservation is not rolled back: it still counts
      // against the hour, conservative rather than granting an extra slot.
      for (var i = 0; i < 59; i++) {
        expect(budget.tryConsume(keyA, now), isTrue);
      }
      expect(budget.tryConsume(keyA, now), isFalse);
    });

    test('a restart in the same device-hour (persist, reload) still '
        'refuses the 61st', () async {
      Map<String, dynamic>? stored;
      final budget = ScopeHourlyBudget(save: (json) async {
        stored = json;
      });
      for (var i = 0; i < 60; i++) {
        budget.tryConsume(keyA, now);
      }
      final ok = await budget.persistReservation(keyA, now ~/ 3600);
      expect(ok, isTrue);
      final reloaded = ScopeHourlyBudget.fromJson(stored,
          save: (json) async {}, nowSec: now);
      expect(reloaded.tryConsume(keyA, now), isFalse);
    });

    test('a restart between a persisted reservation and its enqueue leaves '
        '59 for that hour', () async {
      Map<String, dynamic>? stored;
      final budget = ScopeHourlyBudget(save: (json) async {
        stored = json;
      });
      expect(budget.tryConsume(keyA, now), isTrue);
      final ok = await budget.persistReservation(keyA, now ~/ 3600);
      expect(ok, isTrue);
      // "Restart": a fresh budget rebuilt from what actually landed on disk.
      final reloaded = ScopeHourlyBudget.fromJson(stored,
          save: (json) async {}, nowSec: now);
      var succeeded = 0;
      for (var i = 0; i < 60; i++) {
        if (reloaded.tryConsume(keyA, now)) succeeded++;
      }
      expect(succeeded, 59);
    });

    test('two answers persisting at once both land (serialized writes)', () async {
      final release1 = Completer<void>();
      final firstSaveStarted = Completer<void>();
      final snapshots = <Map<String, dynamic>>[];
      var saveCallCount = 0;
      final budget = ScopeHourlyBudget(save: (json) async {
        saveCallCount++;
        // Capture the snapshot, and signal that this save has genuinely
        // started, before doing anything else: production code fixes the
        // snapshot at the moment it calls `save`, not at the moment `save`
        // finishes, so the test must observe it at that same point.
        snapshots.add(json);
        if (saveCallCount == 1) {
          firstSaveStarted.complete();
          // Hold the first save open so a second, concurrent persist has
          // every chance to jump ahead if writes are not actually
          // serialized.
          await release1.future;
        }
      });

      expect(budget.tryConsume(keyA, now), isTrue);
      final f1 = budget.persistReservation(keyA, now ~/ 3600);

      // Wait for the first save to actually start, with its snapshot
      // already taken, before reserving the second answer. Reserving it any
      // earlier would let both reservations land in `_counts` before either
      // save runs, which proves nothing about write ordering: the fix here
      // is to only make the second reservation once the first save is
      // provably mid-write.
      await firstSaveStarted.future;
      expect(snapshots[0]['$keyA|${now ~/ 3600}'], 1);
      expect(snapshots[0].containsKey('$keyB|${now ~/ 3600}'), isFalse,
          reason:
              'the first save must not see a reservation made after it started');

      expect(budget.tryConsume(keyB, now), isTrue);
      final f2 = budget.persistReservation(keyB, now ~/ 3600);

      // Let every pending microtask and timer run while the first save is
      // still held open. Without serialization the second save would have
      // started (and, being unheld, even landed) by now.
      await Future<void>.delayed(Duration.zero);
      expect(saveCallCount, 1,
          reason: 'the second save must wait for the first to finish');
      expect(snapshots.length, 1, reason: 'the second save has not landed yet');

      release1.complete();
      final results = await Future.wait([f1, f2]);
      expect(results, [isTrue, isTrue]);
      expect(saveCallCount, 2);

      // The second save's own snapshot, the final state actually written,
      // reflects both reservations: no lost update.
      expect(snapshots[1]['$keyA|${now ~/ 3600}'], 1);
      expect(snapshots[1]['$keyB|${now ~/ 3600}'], 1);
    });

    test('two overlapping reservations for the same bucket: it survives '
        'until BOTH complete, not just the first', () async {
      const hour10 = 10;
      const hour13 = 13;
      const hour14 = 14;
      var saveCallCount = 0;
      final release1 = Completer<void>();
      final release2 = Completer<void>();
      final budget = ScopeHourlyBudget(save: (json) async {
        saveCallCount++;
        if (saveCallCount == 1) {
          await release1.future;
        } else if (saveCallCount == 2) {
          await release2.future;
        }
      });

      expect(budget.tryConsume(keyA, hour10 * 3600), isTrue);
      final f1 = budget.persistReservation(keyA, hour10);

      expect(budget.tryConsume(keyA, hour10 * 3600 + 1), isTrue);
      final f2 = budget.persistReservation(keyA, hour10);

      // Let only the first of the two overlapping saves for hour10 finish.
      release1.complete();
      await f1;
      expect(budget.toJson()['$keyA|$hour10'], 2,
          reason: 'the second save for the same bucket has not finished');

      // A much later hour's own persist must not drop the still-in-flight
      // hour10 bucket just because ONE of its two saves finished.
      expect(budget.tryConsume(keyA, hour13 * 3600), isTrue);
      final f13 = budget.persistReservation(keyA, hour13);
      expect(budget.toJson()['$keyA|$hour10'], 2,
          reason: 'hour10 is still in flight (second save not finished)');

      // Finish the second save too.
      release2.complete();
      await Future.wait([f2, f13]);

      // Now that BOTH persists for hour10 are done, it is no longer in
      // flight, and a later persist is free to drop it once it is stale.
      expect(budget.tryConsume(keyA, hour14 * 3600), isTrue);
      await budget.persistReservation(keyA, hour14);
      expect(budget.toJson()['$keyA|$hour10'], isNull,
          reason: 'hour10 finished (both saves) and is now old enough to drop');
    });

    test('an answer consumed at 10:59:59 whose persistence finishes at '
        '11:00:01 keeps the 10:00 bucket until it completes', () async {
      const hour10 = 10;
      const hour13 = 13;
      const hour14 = 14;
      final release = Completer<void>();
      var releaseUsed = false;
      final budget = ScopeHourlyBudget(save: (json) async {
        if (!releaseUsed) {
          releaseUsed = true;
          await release.future;
        }
      });
      expect(budget.tryConsume(keyA, hour10 * 3600 + 3599), isTrue);
      final f10 = budget.persistReservation(keyA, hour10);

      // A much later hour's own reservation must not drop the still-in-flight
      // hour10 bucket just because it is now far older than "the previous
      // hour" relative to hour13.
      expect(budget.tryConsume(keyA, hour13 * 3600), isTrue);
      final f13 = budget.persistReservation(keyA, hour13);
      expect(budget.toJson()['$keyA|$hour10'], 1,
          reason: 'hour10 is still in flight, so it must survive the drop');

      release.complete();
      await Future.wait([f10, f13]);

      // Now that hour10's own persistence has finished, a later drop is free
      // to remove it once it is actually stale.
      expect(budget.tryConsume(keyA, hour14 * 3600), isTrue);
      await budget.persistReservation(keyA, hour14);
      expect(budget.toJson()['$keyA|$hour10'], isNull,
          reason: 'hour10 finished and is now old enough to drop');
    });

    test('fromJson tolerates junk: non-map root, malformed bucket key, '
        'non-numeric count', () {
      final budget = ScopeHourlyBudget.fromJson({
        'no-pipe-here': 5,
        '$keyA|not-a-number': 5,
        '$keyA|$hour': 'not-a-number',
      }, save: noopSave, nowSec: now);
      expect(budget.tryConsume(keyA, now), isTrue);
      expect(budget.canAsk(keyA, now), isTrue);
    });

    test('fromJson drops buckets older than the previous hour', () {
      final budget = ScopeHourlyBudget.fromJson({
        '$keyA|${hour - 2}': 60,
        '$keyA|${hour - 1}': 60,
        '$keyA|$hour': 60,
      }, save: noopSave, nowSec: now);
      // hour-2 is dropped (older than the previous hour), so its slots are
      // not held against a fresh ask in that same old hour.
      expect(budget.tryConsume(keyA, (hour - 2) * 3600), isTrue);
      // hour-1 and hour are both kept and still full.
      expect(budget.tryConsume(keyA, (hour - 1) * 3600), isFalse);
      expect(budget.tryConsume(keyA, hour * 3600), isFalse);
    });
  });
}
