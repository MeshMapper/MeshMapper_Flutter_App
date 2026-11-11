import 'dart:async';

import '../../utils/debug_logger_io.dart';
import '../../utils/public_key.dart';

/// Whether a repeater's scopes should be asked again right now.
///
/// Reads two independent signals, and answers due only when both of them
/// call for a fresh ask:
///
/// - Rule 1, the server side: the server's own `scopesCheckedAt` for this
///   repeater. [onServerList] false (no list at all: offline, not loaded
///   yet) always counts as due on this rule.
/// - Rule 2, the phone side: this phone's own cached [phone] answer, if any.
///
/// [persistPending] is read before either rule: while an earlier answer for
/// this same repeater is still being written (Task 6's detached
/// persistence), the repeater is never due, whatever the two rules would
/// otherwise say.
///
/// [heldUntil] is read next: a repeater this phone asked and got no answer
/// from is held (not due) until that Unix-second deadline, whatever the two
/// rules would otherwise say. Null means no hold. At (not past) the
/// deadline it is due again, so the caller's own [nowSec] decides the
/// boundary, not this function.
bool isScopeQueryDue({
  required bool onServerList,
  required int? serverCheckedAt,
  required ScopeCacheEntry? phone,
  required bool persistPending,
  required int nowSec,
  required int refreshDays,
  int? heldUntil,
}) {
  if (persistPending) return false;
  if (heldUntil != null && nowSec < heldUntil) return false;
  final refreshSec = refreshDays * 86400;
  final rule1 = !onServerList ||
      serverCheckedAt == null ||
      nowSec - serverCheckedAt >= refreshSec;
  final answeredAt = phone?.answeredAt;
  final rule2 = answeredAt == null || nowSec - answeredAt >= refreshSec;
  return rule1 && rule2;
}

/// This phone's own cached answer for one repeater.
///
/// There are no attempt stamps here: a request that got no answer records
/// nothing in [ScopeQueryCache]'s answer map. Instead it starts or extends a
/// separate, memory-only hold (see [ScopeQueryCache.recordNoAnswer]), so
/// this repeater is not re-asked and re-silenced within the same firmware
/// window.
class ScopeCacheEntry {
  /// When this phone last got an answer from the repeater (Unix seconds).
  final int? answeredAt;

  const ScopeCacheEntry({this.answeredAt});
}

/// The phone-side scope answer cache: the secondary guard behind the
/// server's own `scopes_checked_at`. The server already stops re-asks of
/// registered repeaters fleet-wide, and the hourly budget bounds how many
/// answers a phone can hold in the first place, so this cache's own
/// retention can be bounded on purpose (server ruling, round 2) without
/// costing more than an occasional extra zero-hop request.
///
/// Keys are the repeater's full public key, normalized with
/// [normalizePublicKey]; anything that does not normalize is never stored
/// and never returned.
class ScopeQueryCache {
  /// Retention is bounded: once more than this many answers are held, the
  /// oldest are evicted regardless of how fresh the interval says they
  /// still are.
  static const int maxEntries = 20000;

  /// The bound Task 6's runner holds `pendingPersist` to. Named here so both
  /// sides agree on the number; enforcing it (never evicting past it) is the
  /// runner's job, not this cache's.
  static const int maxPendingPersist = 32;

  /// The hold length for each consecutive miss, in order. A miss past the
  /// end of this list holds for [noAnswerHoldMax]. The first step is short
  /// on purpose: a first miss is usually a car at the edge of a repeater's
  /// range, and by 15 minutes it has driven out of range for good.
  static const List<Duration> noAnswerHoldSteps = [
    Duration(minutes: 1),
    Duration(minutes: 5),
    Duration(minutes: 10),
    Duration(minutes: 20),
  ];

  /// The longest a hold ever runs, however many consecutive misses in a
  /// row. Also how long after a miss the stronger-signal rule
  /// ([strongerSignalMarginDb]) stays in force.
  static const Duration noAnswerHoldMax = Duration(minutes: 30);

  /// Once a hold has run out, a retry within [noAnswerHoldMax] of the miss
  /// also needs the repeater heard at least this many dB stronger than it
  /// was at the miss. Re-asking at the same signal would most likely go
  /// unanswered again and spend the repeater's shared anonymous-request
  /// budget (4 per 3 minutes, across every phone) for nothing; a parked
  /// phone therefore waits out the full [noAnswerHoldMax].
  static const int strongerSignalMarginDb = 1;

  final Map<String, ScopeCacheEntry> _entries;

  /// Repeater keys whose answer is still being written to disk (Task 6's
  /// detached persistence). Memory only: never read by [toJson] or
  /// populated by [fromJson].
  final Set<String> pendingPersist = <String>{};

  /// Consecutive no-answer holds, keyed the same way as [_entries]. Memory
  /// only, exactly like [pendingPersist]: never read by [toJson] or
  /// populated by [fromJson], so a hold never survives a relaunch.
  final Map<String, _ScopeHold> _holds = <String, _ScopeHold>{};

  ScopeQueryCache._(this._entries);

  /// Builds a cache from a stored JSON map. Tolerates any junk: a non-map
  /// root, a key that does not normalize to a full public key, or a value
  /// that is not a map with an int (or num) `answeredAt` is simply skipped.
  factory ScopeQueryCache.fromJson(Map<String, dynamic>? json) {
    final entries = <String, ScopeCacheEntry>{};
    if (json != null) {
      json.forEach((rawKey, rawValue) {
        final key = normalizePublicKey(rawKey);
        if (key == null) return;
        if (rawValue is! Map) return;
        final rawAnsweredAt = rawValue['answeredAt'];
        final answeredAt = rawAnsweredAt is int
            ? rawAnsweredAt
            : rawAnsweredAt is num
                ? rawAnsweredAt.toInt()
                : null;
        if (answeredAt == null) return;
        entries[key] = ScopeCacheEntry(answeredAt: answeredAt);
      });
    }
    return ScopeQueryCache._(entries);
  }

  /// Serializes the answer stamps only. [pendingPersist] never rides along:
  /// it names work in flight for this launch, not a durable fact.
  Map<String, dynamic> toJson() => {
        for (final entry in _entries.entries)
          entry.key: {'answeredAt': entry.value.answeredAt},
      };

  /// This repeater's cached answer, or null when it has none or [keyHex]
  /// does not normalize to a full public key.
  ScopeCacheEntry? operator [](String keyHex) {
    final key = normalizePublicKey(keyHex);
    if (key == null) return null;
    return _entries[key];
  }

  /// Records that the repeater answered at [nowSec]. A no-op when [keyHex]
  /// does not normalize to a full public key. Also clears any no-answer
  /// hold and miss count [keyHex] was carrying: an answer means the
  /// repeater is reachable again, so the next silence starts a fresh count.
  void recordAnswer(String keyHex, int nowSec) {
    final key = normalizePublicKey(keyHex);
    if (key == null) return;
    _entries[key] = ScopeCacheEntry(answeredAt: nowSec);
    _holds.remove(key);
  }

  /// Clears any no-answer hold and miss count for [keyHex], without
  /// touching its answer stamp. Unlike [recordAnswer], this is called the
  /// moment a reply PARSES as a valid scope list, whatever happens to its
  /// persistence afterward: the repeater proved it is reachable right then,
  /// so a failed save (or a hourly-cap withholding) must not leave the
  /// miss count in place for the next ask to double from. A no-op when
  /// [keyHex] does not normalize to a full public key.
  void clearHold(String keyHex) {
    final key = normalizePublicKey(keyHex);
    if (key == null) return;
    _holds.remove(key);
  }

  /// The Unix-second deadline before which [keyHex] must not be asked
  /// again, or null when it has no hold (never missed, or its last hold was
  /// cleared by an answer). Also null when [keyHex] does not normalize.
  int? heldUntil(String keyHex) {
    final key = normalizePublicKey(keyHex);
    if (key == null) return null;
    return _holds[key]?.heldUntil;
  }

  /// Whether [keyHex], whose hold has run out, is still waiting for a
  /// stronger signal before it may be asked again: heard at [rssi] now,
  /// less than [strongerSignalMarginDb] above the RSSI it was heard at when
  /// it last missed, and still within [noAnswerHoldMax] of that miss. False
  /// when it has no hold, the miss carried no RSSI, or [keyHex] does not
  /// normalize. Does not look at [heldUntil]; the caller checks that first.
  bool awaitingStrongerSignal(String keyHex,
      {required int nowSec, required int rssi}) {
    final key = normalizePublicKey(keyHex);
    if (key == null) return false;
    final hold = _holds[key];
    final missRssi = hold?.missRssi;
    if (hold == null || missRssi == null) return false;
    if (nowSec - hold.missAt >= noAnswerHoldMax.inSeconds) return false;
    return rssi < missRssi + strongerSignalMarginDb;
  }

  /// Records that an ask to [keyHex] at [nowSec] got no answer: starts or
  /// extends its hold so this phone does not re-ask (and re-silence) it
  /// before the repeater firmware's shared anonymous-request budget has had
  /// a chance to recover, or before the phone is heard better than it was.
  ///
  /// The [missCount]th consecutive miss (no answer landing in between)
  /// holds for the matching [noAnswerHoldSteps] entry, then
  /// [noAnswerHoldMax] past the end of the list. [rssi] is the discovery
  /// RSSI the repeater was heard at for this ask, kept for
  /// [awaitingStrongerSignal]. A no-op when [keyHex] does not normalize to
  /// a full public key.
  void recordNoAnswer(String keyHex, int nowSec, {int? rssi}) {
    final key = normalizePublicKey(keyHex);
    if (key == null) return;
    final missCount = (_holds[key]?.missCount ?? 0) + 1;
    final holdSec = _holdSecondsFor(missCount);
    final heldUntil = nowSec + holdSec;
    _holds[key] = _ScopeHold(
        heldUntil: heldUntil,
        missCount: missCount,
        missAt: nowSec,
        missRssi: rssi);
    debugLog('[SCOPES] ${_logPrefix(key)}: held for '
        '${_describeSeconds(holdSec)} after miss #$missCount'
        '${rssi == null ? '' : ' at $rssi dBm, then needs '
            '${rssi + strongerSignalMarginDb} dBm or better until '
            '${_describeSeconds(noAnswerHoldMax.inSeconds)} after the miss'}');
  }

  /// The hold length for the [missCount]th consecutive miss.
  static int _holdSecondsFor(int missCount) {
    final i = missCount - 1;
    if (i >= 0 && i < noAnswerHoldSteps.length) {
      return noAnswerHoldSteps[i].inSeconds;
    }
    return noAnswerHoldMax.inSeconds;
  }

  static String _logPrefix(String keyHex) =>
      keyHex.length <= 8 ? keyHex : keyHex.substring(0, 8);

  static String _describeSeconds(int sec) {
    if (sec % 3600 == 0) {
      final h = sec ~/ 3600;
      return '$h ${h == 1 ? 'hour' : 'hours'}';
    }
    final m = sec ~/ 60;
    return '$m ${m == 1 ? 'minute' : 'minutes'}';
  }

  /// Drops answers the interval no longer needs, then, only if still over
  /// [maxEntries], evicts the oldest remaining answers to fit.
  ///
  /// Retention follows the interval in force, never a fixed age (the server
  /// allows intervals up to 99999 days): an answer stops blocking a re-ask
  /// once it is older than [refreshDays], so removing it at that point
  /// cannot change any decision [isScopeQueryDue] would make under the same
  /// interval. If the interval later grows, a stamp pruned under a shorter
  /// interval is gone, so that repeater can be asked early once; a known,
  /// accepted edge.
  void prune({required int nowSec, required int refreshDays}) {
    final refreshSec = refreshDays * 86400;
    _entries.removeWhere((_, entry) {
      final answeredAt = entry.answeredAt;
      return answeredAt != null && nowSec - answeredAt >= refreshSec;
    });
    final overflow = _entries.length - maxEntries;
    if (overflow <= 0) return;
    final oldestFirst = _entries.entries.toList()
      ..sort((a, b) =>
          (a.value.answeredAt ?? 0).compareTo(b.value.answeredAt ?? 0));
    for (var i = 0; i < overflow; i++) {
      _entries.remove(oldestFirst[i].key);
    }
    debugLog('[SCOPES] Evicted $overflow scope cache '
        '${overflow == 1 ? 'entry' : 'entries'} over the $maxEntries cap');
  }
}

/// One repeater's no-answer hold, as [ScopeQueryCache] tracks it in memory.
class _ScopeHold {
  /// The Unix-second deadline before which the repeater is not due.
  final int heldUntil;

  /// Consecutive misses (no intervening answer) that produced [heldUntil].
  final int missCount;

  /// When the latest miss happened (Unix seconds).
  final int missAt;

  /// The discovery RSSI the repeater was heard at for the latest miss, or
  /// null when the caller did not know it.
  final int? missRssi;

  const _ScopeHold(
      {required this.heldUntil,
      required this.missCount,
      required this.missAt,
      this.missRssi});
}

/// The per-device-hour cap on `SCOPES` uploads: [perHour] per hour of the
/// answer's own timestamp, matching the server's own cap on the item's
/// timestamp. [deviceKey] is the connected radio's public key, or the
/// session id when there is none (ruling 5); there is no session reset, so
/// the same radio under a new session id is still capped by its own key.
///
/// Restart-safe: [tryConsume] reserves synchronously in memory, so the
/// caller never waits on storage to know whether it may proceed.
/// [persistReservation] then writes that reservation durably, serialized
/// through one internal chain so two answers persisting at once both land
/// instead of one clobbering the other's count.
class ScopeHourlyBudget {
  static const int perHour = 60;

  final Future<void> Function(Map<String, dynamic> json) _save;
  final Map<String, int> _counts = {};

  /// Buckets (`deviceKey|hour`) with one or more [persistReservation] calls
  /// still running, counted by how many: incremented when a call starts,
  /// decremented only when that call's own save settles (success or
  /// failure), whatever turn it happens to be taking on the write chain. A
  /// bucket stays in here (count above zero) as long as any of its calls is
  /// still outstanding, so two overlapping reservations for the same bucket
  /// keep it protected until BOTH finish, not just the first; it is never
  /// dropped as stale while its count is above zero, however old it has
  /// become in the meantime.
  final Map<String, int> _inFlightBuckets = {};

  Future<void> _chain = Future<void>.value();

  ScopeHourlyBudget(
      {required Future<void> Function(Map<String, dynamic> json) save})
      : _save = save;

  /// Loads a persisted budget. Tolerates junk like [ScopeQueryCache] does: a
  /// non-map root, a bucket key with no hour suffix, or a non-numeric count
  /// is skipped. Buckets older than the previous hour (relative to
  /// [nowSec]) are dropped on load, since nothing can be in flight for a
  /// budget that has not run yet.
  factory ScopeHourlyBudget.fromJson(
    Map<String, dynamic>? json, {
    required Future<void> Function(Map<String, dynamic> json) save,
    required int nowSec,
  }) {
    final budget = ScopeHourlyBudget(save: save);
    if (json != null) {
      final currentHour = nowSec ~/ 3600;
      json.forEach((bucketKey, rawCount) {
        final count = rawCount is int
            ? rawCount
            : rawCount is num
                ? rawCount.toInt()
                : null;
        if (count == null) return;
        final hour = _hourOf(bucketKey);
        if (hour == null) return;
        if (hour < currentHour - 1) return;
        budget._counts[bucketKey] = count;
      });
    }
    return budget;
  }

  /// The raw bucket counts, exactly as [persistReservation] would save them
  /// right now. Mainly useful for tests and diagnostics; the durable write
  /// path is [persistReservation], not this.
  Map<String, dynamic> toJson() => Map<String, dynamic>.from(_counts);

  /// True while [deviceKey]'s bucket for the hour [nowSec] falls in still
  /// has room. Read-only: reserves nothing.
  bool canAsk(String deviceKey, int nowSec) =>
      (_counts[_bucketKey(deviceKey, nowSec ~/ 3600)] ?? 0) < perHour;

  /// Reserves one slot in [deviceKey]'s bucket for the hour [answerSec]
  /// falls in, synchronously. False when that hour is already full.
  bool tryConsume(String deviceKey, int answerSec) {
    final key = _bucketKey(deviceKey, answerSec ~/ 3600);
    final count = _counts[key] ?? 0;
    if (count >= perHour) return false;
    _counts[key] = count + 1;
    return true;
  }

  /// Durably persists the reservation [tryConsume] made for [deviceKey]'s
  /// [hour] bucket.
  ///
  /// The bucket is marked in flight for the life of this call (from here
  /// until the returned future settles, not merely for as long as this
  /// call's own turn on the write chain takes), so a later call's
  /// stale-bucket drop never removes an answer whose own persistence has
  /// not finished, however old that bucket has become in the meantime.
  ///
  /// Resolves false when [save] throws; the in-memory reservation stays
  /// counted regardless, which is conservative: a failed write drops the
  /// answer, it never grants an extra slot.
  Future<bool> persistReservation(String deviceKey, int hour) {
    final bucketKey = _bucketKey(deviceKey, hour);
    _inFlightBuckets[bucketKey] = (_inFlightBuckets[bucketKey] ?? 0) + 1;
    _dropStale(hour);
    final result = Completer<bool>();
    _chain = _chain.then((_) async {
      try {
        await _save(Map<String, dynamic>.from(_counts));
        result.complete(true);
      } catch (e) {
        debugWarn('[SCOPES] Failed to persist scope hour budget: $e');
        result.complete(false);
      } finally {
        final remaining = (_inFlightBuckets[bucketKey] ?? 1) - 1;
        if (remaining <= 0) {
          _inFlightBuckets.remove(bucketKey);
        } else {
          _inFlightBuckets[bucketKey] = remaining;
        }
      }
    });
    return result.future;
  }

  /// Drops buckets older than the previous hour relative to [currentHour],
  /// except one still counted in [_inFlightBuckets].
  void _dropStale(int currentHour) {
    _counts.removeWhere((key, _) {
      if (_inFlightBuckets.containsKey(key)) return false;
      final hour = _hourOf(key);
      return hour != null && hour < currentHour - 1;
    });
  }

  static String _bucketKey(String deviceKey, int hour) => '$deviceKey|$hour';

  static int? _hourOf(String bucketKey) {
    final i = bucketKey.lastIndexOf('|');
    if (i < 0) return null;
    return int.tryParse(bucketKey.substring(i + 1));
  }
}
