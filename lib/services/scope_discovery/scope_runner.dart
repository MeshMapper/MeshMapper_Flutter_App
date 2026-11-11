import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:geolocator/geolocator.dart';

import '../../models/scope_log_entry.dart';
import '../../utils/debug_logger_io.dart';
import '../../utils/public_key.dart';
import '../meshcore/connection.dart';
import '../meshcore/scope_lease.dart';
import 'scope_discovery_rules.dart';
import 'scope_regions_codec.dart';

/// One repeater a discovery sweep found, as the runner sees it.
///
/// [keyHex] is the full upper-case public key, [lat]/[lon] the discovery
/// point, [localRssi]/[localSnr] the reply as this phone heard it, and
/// [discoveryReplyAfter] how long after the discovery command was submitted
/// that reply arrived (null for a reply to another phone's discovery).
typedef ScopeCandidate = ({
  String keyHex,
  String repeaterId,
  double lat,
  double lon,
  int localRssi,
  double localSnr,
  Duration? discoveryReplyAfter,
});

/// The radio as the runner uses it: one lease at a time.
abstract class ScopeRadio {
  /// A short exclusive hold on the radio, or null when it was not admitted
  /// within [admissionWait] or [cancel] fired first.
  Future<ScopeLeaseHandle?> acquire(
      {required Duration admissionWait, required ScopeCancelToken cancel});
}

/// One granted lease: the test seam over `ScopeLease`.
abstract class ScopeLeaseHandle {
  /// Asks [pubkey] for its scopes (see `ScopeLease.requestScopes`). Releases
  /// the lease itself before the answer wait.
  Future<ScopeRequestOutcome> requestScopes(Uint8List pubkey, Uint8List request,
      {required Duration? answerWait,
      required DateTime notAfter,
      void Function(Duration wait)? onSent});

  /// Writes a borrowed record back; true once the radio confirmed it.
  Future<bool> restore(ContactRecord original);

  /// Records whose borrowed route has not been written back yet.
  List<ContactRecord> get unrestored;

  /// Ends the lease now. Idempotent.
  Future<void> release();
}

/// [ScopeRadio] over a live [MeshCoreConnection].
class MeshCoreScopeRadio implements ScopeRadio {
  final MeshCoreConnection _connection;

  MeshCoreScopeRadio(this._connection);

  @override
  Future<ScopeLeaseHandle?> acquire(
          {required Duration admissionWait,
          required ScopeCancelToken cancel}) =>
      _connection.acquireScopeLease(
          admissionWait: admissionWait, cancel: cancel);
}

/// One answer on its way to the upload queue.
class ScopeAnswer {
  final String keyHex;
  final List<String> scopes;

  /// The discovery point.
  final double lat;
  final double lon;

  /// When the answer arrived (Unix seconds).
  final int timestampSec;

  const ScopeAnswer({
    required this.keyHex,
    required this.scopes,
    required this.lat,
    required this.lon,
    required this.timestampSec,
  });
}

/// What an answer's detached persistence captured when it was received, so
/// it never reads state that moved on after the runner ended.
class ScopePersistContext {
  final String deviceKey;
  final String? sessionId;
  final int queueGeneration;
  final int budgetHour;

  const ScopePersistContext({
    required this.deviceKey,
    required this.sessionId,
    required this.queueGeneration,
    required this.budgetHour,
  });
}

/// Runs writes one after another. A write that throws is logged and never
/// stops the next one.
class ScopeSerialWriter {
  final Future<void> Function() _write;
  final String _what;
  Future<void> _chain = Future<void>.value();

  ScopeSerialWriter(this._what, this._write);

  /// Queues one write of the current state. Resolves when it has run.
  Future<void> schedule() {
    final next = _chain.then((_) async {
      try {
        await _write();
      } catch (e) {
        debugWarn('[SCOPES] Failed to save the $_what: $e');
      }
    });
    _chain = next;
    return next;
  }
}

/// Asks up to [maxAsksPerSweep] repeaters one discovery sweep found for
/// their scope list, strongest first, one at a time, in the background.
///
/// Built per sweep. Nothing about the ping schedule waits on it: every ask
/// that would run past [hardStop] (the earliest the next discovery can go
/// out) is not started, and the runner is cancelled outright by the next
/// discovery send, every stop path and its own hard-stop timer. An answer is
/// persisted detached from the runner, so a late answer still lands in the
/// queue and the cache after the runner has ended.
class ScopeRunner {
  /// At most this many asks per sweep.
  static const int maxAsksPerSweep = 3;

  /// The longest answer wait for one ask.
  static const Duration maxWaitPerAsk = Duration(seconds: 7);

  /// Added to the repeater's discovery reply time for its answer wait.
  static const Duration discoveryReplyMargin = Duration(seconds: 2);

  /// A runner never outlives this, whatever hard stop it was given.
  static const Duration maxRunnerLifetime = Duration(seconds: 30);

  /// The phone may drift this far from the discovery point and still ask.
  static const double scopeMaxDriftMeters = 300;

  /// How long one ask waits to be admitted to the radio.
  static const Duration leaseAdmissionWait = Duration(seconds: 3);

  /// How long the runner waits for the sweep's DISC items to be persisted.
  static const Duration discPersistWait = Duration(seconds: 2);

  final ScopeRadio _radio;
  final ScopeCancelToken _cancel;
  final DateTime _hardStop;
  final int Function() _refreshDays;
  final String Function() _deviceKey;
  final String? Function() _sessionId;
  final int Function() _queueGeneration;
  final ({bool onList, int? checkedAt}) Function(String keyHex) _serverInfo;
  final ScopeQueryCache _cache;
  final ScopeHourlyBudget _budget;
  final Future<bool> Function(ScopeAnswer, ScopePersistContext) _enqueue;
  final void Function() _onCacheStamped;
  final int Function() _nowSec;
  final ({double lat, double lon})? Function() _currentPosition;
  final bool Function() _stillWanted;
  final void Function(bool active) _onActiveChanged;
  final void Function(ScopeLogEntry entry) _onLogged;
  final List<ContactRecord> _pendingRestores;
  final Set<String> _knownNonContacts;
  final bool Function() _cannotAskNonContacts;

  /// Set by the owner (PingService): false once this runner is no longer
  /// the live one, so a late continuation never moves a newer runner's
  /// badge. Always true when unset.
  bool Function()? isCurrent;

  bool _active = false;
  bool _started = false;
  String? _stopReason;
  ScopeLeaseHandle? _lease;
  Timer? _hardStopTimer;

  /// The upload queue's generation when this sweep's DISC items were known
  /// to be queued. Every answer of the sweep is enqueued against it, so a
  /// queue cleared mid-sweep (which took those DISC items with it) refuses
  /// the answers instead of queuing a SCOPES item the server would drop.
  int? _sweepGeneration;

  ScopeRunner({
    required ScopeRadio radio,
    required ScopeCancelToken cancel,
    required DateTime hardStop,
    required int Function() refreshDays,
    required String Function() deviceKey,
    required ({bool onList, int? checkedAt}) Function(String keyHex)
        serverInfo,
    required ScopeQueryCache cache,
    required ScopeHourlyBudget budget,
    required Future<bool> Function(ScopeAnswer, ScopePersistContext) enqueue,
    required int Function() nowSec,
    required ({double lat, double lon})? Function() currentPosition,
    required bool Function() stillWanted,
    required void Function(bool active) onActiveChanged,
    required void Function(ScopeLogEntry entry) onLogged,
    required List<ContactRecord> pendingRestores,
    String? Function()? sessionId,
    int Function()? queueGeneration,
    void Function()? onCacheStamped,
    Set<String>? knownNonContacts,
    bool Function()? cannotAskNonContacts,
  })  : _radio = radio,
        _cancel = cancel,
        _hardStop = hardStop,
        _refreshDays = refreshDays,
        _deviceKey = deviceKey,
        _sessionId = sessionId ?? (() => null),
        _queueGeneration = queueGeneration ?? (() => 0),
        _serverInfo = serverInfo,
        _cache = cache,
        _budget = budget,
        _enqueue = enqueue,
        _onCacheStamped = onCacheStamped ?? (() {}),
        _nowSec = nowSec,
        _currentPosition = currentPosition,
        _stillWanted = stillWanted,
        _onActiveChanged = onActiveChanged,
        _onLogged = onLogged,
        _pendingRestores = pendingRestores,
        _knownNonContacts = knownNonContacts ?? <String>{},
        _cannotAskNonContacts = cannotAskNonContacts ?? (() => false);

  /// True once [cancel] ran or the token fired.
  bool get isCancelled => _cancel.isCancelled;

  /// Stops the runner now: the token fires (the lease checks it before
  /// every write and at admission), a lease still held is released, and
  /// the badge clears. Idempotent.
  void cancel([String reason = 'cancelled']) {
    if (_cancel.isCancelled) return;
    _stopReason ??= reason;
    debugLog('[SCOPES] Runner stopped: $reason');
    _cancel.cancel();
    final lease = _lease;
    if (lease != null) unawaited(lease.release());
    _setActive(false);
  }

  /// Runs the sweep. Never throws: an unexpected error is logged and ends
  /// the runner.
  Future<void> run(List<ScopeCandidate> found,
      {required Future<void> discPersisted}) async {
    if (_started) return;
    _started = true;
    try {
      await _run(found, discPersisted);
    } catch (e, st) {
      debugError('[SCOPES] Runner failed: $e');
      debugError('[SCOPES] $st');
    } finally {
      _hardStopTimer?.cancel();
      _hardStopTimer = null;
      _setActive(false);
      final lease = _lease;
      _lease = null;
      if (lease != null) {
        try {
          await lease.release();
        } catch (_) {}
      }
    }
  }

  Future<void> _run(
      List<ScopeCandidate> found, Future<void> discPersisted) async {
    if (_cancel.isCancelled) return;
    final startedAt = clock.now();
    final lifetimeEnd = startedAt.add(maxRunnerLifetime);
    final hardStop = _hardStop.isBefore(lifetimeEnd) ? _hardStop : lifetimeEnd;
    final untilStop = hardStop.difference(startedAt);
    if (untilStop <= Duration.zero) {
      _stop('hard stop already passed');
      return;
    }
    _hardStopTimer = Timer(untilStop, () => cancel('hard stop'));

    // The server only accepts a SCOPES item after the DISC that found the
    // repeater, so the sweep's DISC items must be safely queued first.
    final persisted = await _within(discPersisted, discPersistWait);
    if (_cancel.isCancelled) return;
    if (!persisted) {
      _stop('DISC items not persisted within '
          '${discPersistWait.inSeconds}s');
      return;
    }
    _sweepGeneration = _queueGeneration();

    final nowSec = _nowSec();
    final refreshDays = _refreshDays();
    final cannotAskNonContacts = _cannotAskNonContacts();
    final due = <ScopeCandidate>[];
    var heldCount = 0;
    var weakCount = 0;
    var blockedCount = 0;
    for (final c in found) {
      final key = normalizePublicKey(c.keyHex);
      if (key == null) continue;
      // Filtered before the top-3 cut, not inside _ask: a known non-contact
      // must never occupy a slot a weaker, askable repeater (a saved
      // contact, or one not yet proven non-contact) could have used.
      if (cannotAskNonContacts && _knownNonContacts.contains(key)) {
        blockedCount++;
        continue;
      }
      final info = _serverInfo(key);
      final heldUntil = _cache.heldUntil(key);
      if (heldUntil != null && nowSec < heldUntil) {
        heldCount++;
        continue;
      }
      // The hold has run out, but a repeater that missed is only worth
      // asking again once it is heard clearly better than at the miss.
      if (_cache.awaitingStrongerSignal(key,
          nowSec: nowSec, rssi: c.localRssi)) {
        weakCount++;
        continue;
      }
      if (isScopeQueryDue(
          onServerList: info.onList,
          serverCheckedAt: info.checkedAt,
          phone: _cache[key],
          persistPending: _cache.pendingPersist.contains(key),
          nowSec: nowSec,
          refreshDays: refreshDays,
          heldUntil: heldUntil)) {
        due.add(c);
      }
    }
    due.sort((a, b) {
      final r = b.localRssi.compareTo(a.localRssi);
      if (r != 0) return r;
      final s = b.localSnr.compareTo(a.localSnr);
      if (s != 0) return s;
      return a.keyHex.toUpperCase().compareTo(b.keyHex.toUpperCase());
    });
    final chosen = due.take(maxAsksPerSweep).toList();
    debugLog('[SCOPES] Sweep: found ${found.length}, due ${due.length}, '
        'held $heldCount, weak $weakCount, blocked $blockedCount, '
        'chosen ${chosen.map((c) => _prefix(c.keyHex)).join(', ')}');

    for (final c in chosen) {
      if (!await _ask(c, hardStop)) return;
    }
  }

  /// One ask. False when the runner should stop.
  Future<bool> _ask(ScopeCandidate c, DateTime hardStop) async {
    final key = normalizePublicKey(c.keyHex)!;
    final label = _prefix(key);
    final wait = _waitFor(c);
    if (!_mayAsk(c)) return false;
    final needed = leaseAdmissionWait + kScopeLeaseHold + wait;
    if (clock.now().add(needed).isAfter(hardStop)) {
      _stop('the ask to $label would run past the next discovery');
      return false;
    }

    _setActive(true);
    final lease = await _radio.acquire(
        admissionWait: leaseAdmissionWait, cancel: _cancel);
    if (lease == null) {
      _setActive(false);
      if (!_cancel.isCancelled) _stop('radio not admitted for $label');
      return false;
    }
    _lease = lease;
    if (_cancel.isCancelled) return false;
    if (!_stillWanted()) {
      _stop('no longer wanted');
      return false;
    }
    // The lease holds for at most kScopeLeaseHold, and the answer wait
    // starts no later than that, so this is the last point the ask can be
    // shown to finish before the hard stop.
    if (clock.now().add(kScopeLeaseHold + wait).isAfter(hardStop)) {
      _stop('admission for $label came too late for the next discovery');
      return false;
    }

    // Routes borrowed by an earlier runner on this connection go back
    // before anything else is written.
    for (final record in List.of(_pendingRestores)) {
      if (_cancel.isCancelled) return false;
      if (await lease.restore(record)) {
        _pendingRestores.removeWhere(
            (r) => _sameBytes(r.publicKey, record.publicKey));
      }
    }
    if (_cancel.isCancelled) return false;

    final outcome = await lease.requestScopes(
        _bytes(key), buildRegionsRequest(),
        answerWait: c.discoveryReplyAfter == null ? null : wait,
        notAfter: hardStop);
    _lease = null;
    _keepUnrestored(lease, outcome);
    _setActive(false);

    switch (outcome) {
      case ScopeAnswered(:final body, :final receivedAt):
        if (_cancel.isCancelled) return false;
        _handleAnswer(c, key, body, receivedAt);
        return !_cancel.isCancelled;
      case ScopeNoAnswer():
        if (_cancel.isCancelled) return false;
        debugLog('[SCOPES] $label: no response');
        _cache.recordNoAnswer(key, _nowSec(), rssi: c.localRssi);
        _log(c, key, ScopeLogOutcome.noResponse);
        return true;
      case ScopeFlooded():
        debugLog('[SCOPES] $label: flooded by the radio');
        _log(c, key, ScopeLogOutcome.flooded);
        return !_cancel.isCancelled;
      case ScopeRadioError(:final code, :final nonContactTableFull):
        debugLog('[SCOPES] $label: radio error $code');
        if (nonContactTableFull) {
          _knownNonContacts.add(key);
          _log(c, key, ScopeLogOutcome.radioContactsFull);
        } else {
          _log(c, key, ScopeLogOutcome.radioError);
        }
        return !_cancel.isCancelled;
      case ScopeLocalFailure(:final why):
        _stop('local failure asking $label ($why)');
        return false;
      case ScopeAborted():
        if (!_cancel.isCancelled) _stop('ask to $label aborted');
        return false;
      case ScopeNonContactRefused():
        debugLog('[SCOPES] $label: not a contact and this connection cannot '
            'ask non-contacts, nothing sent');
        _knownNonContacts.add(key);
        return !_cancel.isCancelled;
    }
  }

  void _handleAnswer(
      ScopeCandidate c, String key, Uint8List body, DateTime receivedAt) {
    final label = _prefix(key);
    final receivedSec = receivedAt.millisecondsSinceEpoch ~/ 1000;
    final names = parseRegionsReply(body);
    if (names == null) {
      debugLog('[SCOPES] $label: unreadable answer (${body.length} bytes)');
      _log(c, key, ScopeLogOutcome.malformed, at: receivedAt);
      return;
    }
    // It parsed: the repeater proved it is reachable right now, whatever
    // happens to the upload below. Clearing the hold here, not only once
    // persistence succeeds, means a failed save never leaves the miss count
    // in place for the next ask to double from.
    _cache.clearHold(key);
    final deviceKey = _deviceKey();
    if (!_budget.tryConsume(deviceKey, receivedSec)) {
      debugLog('[SCOPES] $label: answered [${names.join(', ')}], withheld '
          '(hourly cap)');
      _log(c, key, ScopeLogOutcome.withheldHourlyCap,
          at: receivedAt, scopes: names);
      return;
    }
    debugLog('[SCOPES] $label: answered [${names.join(', ')}]');
    _log(c, key, ScopeLogOutcome.answered, at: receivedAt, scopes: names);
    final answer = ScopeAnswer(
        keyHex: key,
        scopes: List.unmodifiable(names),
        lat: c.lat,
        lon: c.lon,
        timestampSec: receivedSec);
    final ctx = ScopePersistContext(
        deviceKey: deviceKey,
        sessionId: _sessionId(),
        queueGeneration: _sweepGeneration ?? _queueGeneration(),
        budgetHour: receivedSec ~/ 3600);
    unawaited(_persist(answer, ctx));
  }

  /// Detached: reserves the hour durably, queues the answer, and stamps the
  /// cache only once the queue accepted it. Touches no runner, badge, timer
  /// or schedule state, so it may finish long after the runner ended.
  Future<void> _persist(ScopeAnswer answer, ScopePersistContext ctx) async {
    final key = answer.keyHex;
    final label = _prefix(key);
    _cache.pendingPersist.add(key);
    try {
      final reserved =
          await _budget.persistReservation(ctx.deviceKey, ctx.budgetHour);
      if (!reserved) {
        debugWarn('[SCOPES] $label: hour reservation not saved, answer '
            'dropped');
        return;
      }
      final accepted = await _enqueue(answer, ctx);
      if (!accepted) {
        debugWarn('[SCOPES] $label: answer not queued, dropped');
        return;
      }
      _cache.recordAnswer(key, answer.timestampSec);
      _onCacheStamped();
      debugLog('[SCOPES] $label: answer queued');
    } catch (e) {
      debugError('[SCOPES] $label: persisting the answer failed: $e');
    } finally {
      _cache.pendingPersist.remove(key);
    }
  }

  /// The checks every ask passes before it starts.
  bool _mayAsk(ScopeCandidate c) {
    if (_cancel.isCancelled) return false;
    if (!_stillWanted()) {
      _stop('no longer wanted');
      return false;
    }
    final deviceKey = _deviceKey();
    if (!_budget.canAsk(deviceKey, _nowSec())) {
      _stop('hourly cap reached');
      return false;
    }
    if (_cache.pendingPersist.length >= ScopeQueryCache.maxPendingPersist) {
      _stop('too many answers still being saved');
      return false;
    }
    final here = _currentPosition();
    if (here != null) {
      final drift =
          Geolocator.distanceBetween(c.lat, c.lon, here.lat, here.lon);
      if (drift > scopeMaxDriftMeters) {
        _stop('moved ${drift.round()}m from the discovery point');
        return false;
      }
    }
    return true;
  }

  /// The answer wait for [c]: its discovery reply time plus the margin,
  /// capped; the cap when the reply time is unknown (the radio's estimate is
  /// only known after SENT, so the cap is what is reserved).
  static Duration _waitFor(ScopeCandidate c) {
    final after = c.discoveryReplyAfter;
    if (after == null) return maxWaitPerAsk;
    final wait = after + discoveryReplyMargin;
    return wait > maxWaitPerAsk ? maxWaitPerAsk : wait;
  }

  /// Keeps every record the lease could not write back, for the next runner
  /// on this connection.
  void _keepUnrestored(ScopeLeaseHandle lease, ScopeRequestOutcome outcome) {
    final owed = <ContactRecord>[
      ...lease.unrestored,
      if (outcome.restoreOwed && outcome.borrowedFrom != null)
        outcome.borrowedFrom!,
    ];
    for (final record in owed) {
      if (_pendingRestores
          .any((r) => _sameBytes(r.publicKey, record.publicKey))) {
        continue;
      }
      _pendingRestores.add(record);
      debugLog('[SCOPES] Route to ${_prefix(_hexOf(record.publicKey))} '
          'kept for a later restore');
    }
  }

  void _log(ScopeCandidate c, String key, ScopeLogOutcome outcome,
      {DateTime? at, List<String>? scopes}) {
    try {
      _onLogged(ScopeLogEntry(
          timestamp: at ?? clock.now(),
          latitude: c.lat,
          longitude: c.lon,
          repeaterId: c.repeaterId,
          pubkeyHex: key,
          outcome: outcome,
          scopes: scopes));
    } catch (e) {
      debugError('[SCOPES] Log entry failed: $e');
    }
  }

  void _stop(String reason) {
    if (_stopReason != null) return;
    _stopReason = reason;
    debugLog('[SCOPES] Runner stopped: $reason');
  }

  /// Moves the badge. After a cancel nothing moves it again, and a runner
  /// that is no longer current never moves it at all.
  void _setActive(bool active) {
    if (_active == active) return;
    if (active && _cancel.isCancelled) return;
    _active = active;
    final current = isCurrent?.call() ?? true;
    if (!current) return;
    try {
      _onActiveChanged(active);
    } catch (e) {
      debugError('[SCOPES] Badge update failed: $e');
    }
  }

  /// Resolves true when [f] completes within [limit], false on a timeout,
  /// an error or a cancel.
  Future<bool> _within(Future<void> f, Duration limit) {
    final done = Completer<bool>();
    final timer = Timer(limit, () {
      if (!done.isCompleted) done.complete(false);
    });
    f.then((_) {
      if (!done.isCompleted) done.complete(true);
    }, onError: (Object e) {
      debugWarn('[SCOPES] DISC items failed to persist: $e');
      if (!done.isCompleted) done.complete(false);
    });
    _cancel.whenCancelled.then((_) {
      if (!done.isCompleted) done.complete(false);
    });
    return done.future.whenComplete(timer.cancel);
  }

  static Uint8List _bytes(String hex) => Uint8List.fromList([
        for (var i = 0; i < hex.length; i += 2)
          int.parse(hex.substring(i, i + 2), radix: 16),
      ]);

  static String _hexOf(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Public keys are logged as an 8-character prefix only.
  static String _prefix(String keyHex) =>
      keyHex.length <= 8 ? keyHex : keyHex.substring(0, 8);
}
