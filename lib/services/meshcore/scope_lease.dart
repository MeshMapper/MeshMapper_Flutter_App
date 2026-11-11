import 'dart:async';
import 'dart:typed_data';

import 'package:clock/clock.dart';

import '../../utils/debug_logger_io.dart';
import '../scope_discovery/scope_runner.dart' show ScopeLeaseHandle;
import 'buffer_utils.dart';
import 'connection.dart' show ContactRecord;
import 'protocol_constants.dart';

/// How long one lease may hold the radio, counted from the grant. Covers
/// everything the lease does: earlier restores, the lookup, the borrow, the
/// send, SENT and this ask's restore.
const Duration kScopeLeaseHold = Duration(seconds: 4);

/// The least time left before the lease deadline for which a new command (or
/// a restore) is still written.
const Duration kScopeLeaseMinCommandTime = Duration(milliseconds: 500);

/// The longest the answer wait may run, counted from SENT.
const Duration kScopeAnswerWaitCap = Duration(seconds: 7);

/// Added to the radio's `est_timeout` when the caller gives no answer wait.
const Duration kScopeAnswerFallbackMargin = Duration(seconds: 1);

/// The scope runner's cancellation: Stop, force disable, the hard stop or a
/// disconnect. Checked when a lease is granted and before every write the
/// lease makes.
class ScopeCancelToken {
  final Completer<void> _cancelled = Completer<void>();

  /// True once [cancel] has run.
  bool get isCancelled => _cancelled.isCompleted;

  /// Fires the token. Idempotent.
  void cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }

  /// Completes (never with an error) when the token fires.
  Future<void> get whenCancelled => _cancelled.future;
}

/// What one scope request came to. Nothing in the request throws: every
/// failure is one of these.
///
/// [borrowedFrom] is the contact record as read when its route was borrowed
/// for the send, and [restoreOwed] is true while that record has not been
/// written back (the caller keeps it for the next lease).
sealed class ScopeRequestOutcome {
  final bool restoreOwed;
  final ContactRecord? borrowedFrom;

  const ScopeRequestOutcome({this.restoreOwed = false, this.borrowedFrom});
}

/// The repeater answered. [body] is the reply with the tag removed, the
/// repeater's 4-byte clock still at the front. [receivedAt] is when the push
/// arrived.
final class ScopeAnswered extends ScopeRequestOutcome {
  final Uint8List body;
  final DateTime receivedAt;

  const ScopeAnswered(this.body, this.receivedAt,
      {super.restoreOwed, super.borrowedFrom});
}

/// The request went out and no matching answer arrived in time.
final class ScopeNoAnswer extends ScopeRequestOutcome {
  const ScopeNoAnswer({super.restoreOwed, super.borrowedFrom});
}

/// The radio flooded the request instead of sending it direct.
final class ScopeFlooded extends ScopeRequestOutcome {
  const ScopeFlooded({super.restoreOwed, super.borrowedFrom});
}

/// The radio answered a step with ERR [code].
final class ScopeRadioError extends ScopeRequestOutcome {
  final int code;

  /// True when this was ERR_CODE_TABLE_FULL answering a send to a repeater
  /// the lookup just found is not a saved contact: the connection-level
  /// "cannot ask non-contacts" flag was set (or already set) because of
  /// this ask. False for every other ERR, including the same code answering
  /// a saved contact.
  final bool nonContactTableFull;

  const ScopeRadioError(this.code,
      {this.nonContactTableFull = false,
      super.restoreOwed,
      super.borrowedFrom});
}

/// The repeater was not a saved contact and this connection cannot ask
/// non-contacts (a send already came back ERR_CODE_TABLE_FULL for one on
/// this connection). Nothing beyond the lookup was written for this ask.
final class ScopeNonContactRefused extends ScopeRequestOutcome {
  const ScopeNonContactRefused();
}

/// A local stop: `hold_cap` (the lease deadline), `malformed_sent`,
/// `write_failed` or `reply_owed` (a reply that was not the one expected).
final class ScopeLocalFailure extends ScopeRequestOutcome {
  final String why;

  const ScopeLocalFailure(this.why, {super.restoreOwed, super.borrowedFrom});
}

/// Cancelled, or the connection went away.
final class ScopeAborted extends ScopeRequestOutcome {
  const ScopeAborted({super.restoreOwed, super.borrowedFrom});
}

/// The tagged answer push: the body after the tag, and when it arrived.
typedef ScopeAnswerPush = ({Uint8List body, DateTime receivedAt});

/// The connection-side primitives a [ScopeLease] runs on. Implemented by
/// `MeshCoreConnection` only; nothing else should call these.
abstract interface class ScopeLeaseHost {
  /// True when no reply is owed for any command already written.
  bool get repliesSettled;

  /// Writes [frame] for [lease], past the lease gate. Resolves false when the
  /// lease ended or was cancelled before the frame reached the transport;
  /// throws when the transport write throws.
  Future<bool> writeForLease(ScopeLease lease, Uint8List frame);

  /// Hands the next reply frame (code below 0x80) to [waiter], exactly once,
  /// ahead of every other owner. Null clears it.
  void setLeaseReplyWaiter(
      ScopeLease lease, void Function(Uint8List frame)? waiter);

  /// Arms the answer slot before the send is written.
  Future<ScopeAnswerPush> armScopeAnswer();

  /// Installs the tag the answer must carry (called inside the SENT dispatch).
  void setScopeAnswerTag(Uint8List tag);

  /// Drops the answer slot and its tag, so a late answer is ignored.
  void disarmScopeAnswer();

  /// Ends [lease]: opens the gate, resumes the pollers. With [listen] the
  /// admin slot passes to a scope-listen token for the answer wait; without
  /// it the slot is freed and the answer slot disarmed.
  void endLease(ScopeLease lease, {required bool listen});

  /// Ends the answer wait: disarms the answer slot and frees the admin slot.
  void endListen();

  /// True once a send to a repeater not among this connection's saved
  /// contacts came back ERR_CODE_TABLE_FULL (a companion firmware bug: the
  /// radio needs a contact-table slot for `CMD_SEND_ANON_REQ` and has none
  /// free, fixed in v1.17.0's 8 reserved transient slots). Sticky for the
  /// life of the connection.
  bool get cannotAskNonContacts;

  /// Records that this connection cannot ask a repeater that is not a saved
  /// contact. Idempotent.
  void markCannotAskNonContacts();
}

enum _LeaseEnd { released, holdCap, cancelled, disconnected }

sealed class _Reply {
  const _Reply();
}

final class _Frame extends _Reply {
  final Uint8List frame;
  const _Frame(this.frame);
}

final class _Ended extends _Reply {
  final _LeaseEnd why;
  const _Ended(this.why);
}

final class _NotWritten extends _Reply {
  final String why;
  const _NotWritten(this.why);
}

final class _WriteFailed extends _Reply {
  final Object error;
  const _WriteFailed(this.error);
}

/// A short exclusive hold on the radio for one scope ask.
///
/// The radio's OK, ERR, CONTACT and SENT replies carry no correlation, so
/// while a lease is held every other command waits at a gate and every reply
/// is the lease's. The lease writes one command at a time and waits for its
/// reply before the next. It ends at [kScopeLeaseHold] after the grant
/// whatever is in flight (a stalled transport write included), on cancel, on
/// disconnect, or when [requestScopes] has its SENT and restore in.
///
/// Created only by `MeshCoreConnection.acquireScopeLease`.
class ScopeLease implements ScopeLeaseHandle {
  final ScopeLeaseHost _host;
  final ScopeCancelToken _cancel;
  final DateTime _deadline;
  Timer? _deadlineTimer;

  bool _active = true;
  _LeaseEnd? _endReason;
  Completer<_Reply>? _pending;
  bool _tagArmed = false;
  final List<ContactRecord> _unrestored = [];

  /// Grants a lease that holds for [hold]. Connection use only.
  ScopeLease(
      {required ScopeLeaseHost host,
      required ScopeCancelToken cancel,
      Duration hold = kScopeLeaseHold})
      : _host = host,
        _cancel = cancel,
        _deadline = clock.now().add(hold) {
    _deadlineTimer = Timer(hold, _onDeadline);
    unawaited(cancel.whenCancelled.then((_) => _onCancel()));
  }

  /// True until the lease is released, runs out, is cancelled or aborted.
  bool get active => _active;

  /// True once the runner's cancel token has fired.
  bool get cancelled => _cancel.isCancelled;

  /// Records whose borrowed route has not been written back yet, oldest
  /// first. A record joins before its borrow is written and leaves only when
  /// its restore's OK arrives.
  @override
  List<ContactRecord> get unrestored => List.unmodifiable(_unrestored);

  /// Asks the repeater [pubkey] for its scopes with [request]: look it up,
  /// borrow a zero-hop route when it has another one, send, restore, then
  /// release the lease and wait for the tagged answer outside it.
  ///
  /// The answer wait is [answerWait] (or the radio's estimate plus 1 s when
  /// null), at most [kScopeAnswerWaitCap], counted from SENT and never past
  /// [notAfter]. [onSent] fires with that wait once the answer tag is armed.
  @override
  Future<ScopeRequestOutcome> requestScopes(Uint8List pubkey, Uint8List request,
      {required Duration? answerWait,
      required DateTime notAfter,
      void Function(Duration wait)? onSent}) async {
    ContactRecord? borrowed;
    try {
      return await _request(pubkey, request, answerWait, notAfter, onSent,
          (record) => borrowed = record);
    } catch (e) {
      debugError('[SCOPES] Scope request failed unexpectedly: $e');
      _end(_LeaseEnd.released);
      _host.endListen();
      return ScopeAborted(restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
    }
  }

  Future<ScopeRequestOutcome> _request(
      Uint8List pubkey,
      Uint8List request,
      Duration? answerWait,
      DateTime notAfter,
      void Function(Duration wait)? onSent,
      void Function(ContactRecord record) noteBorrow) async {
    final label = _prefix(pubkey);
    if (!_active) return _stopped(_Ended(_endReason!), null);

    // Stage 1: is the repeater a contact, and with which route?
    final lookup = await _exchange(
        Uint8List.fromList([CommandCodes.getContactByKey, ...pubkey]));
    if (lookup is! _Frame) return _stopped(lookup, null);
    ContactRecord? contact;
    final lf = lookup.frame;
    if (lf[0] == ResponseCodes.contact) {
      try {
        contact = ContactRecord.parse(BufferReader(lf.sublist(1)));
      } on FormatException catch (e) {
        debugWarn('[SCOPES] Lookup for $label returned a short contact: $e');
        return _localFailure('reply_owed', null);
      }
      if (!_sameBytes(contact.publicKey, pubkey)) {
        debugWarn('[SCOPES] Lookup for $label answered with contact '
            '${_prefix(contact.publicKey)}, not accepted');
        return _localFailure('reply_owed', null);
      }
    } else if (lf[0] == ResponseCodes.err) {
      final code = lf.length > 1 ? lf[1] : 0;
      if (code != ErrorCodes.notFound) {
        debugWarn('[SCOPES] Lookup for $label refused (error code $code)');
        return _radioError(code, null);
      }
      debugLog('[SCOPES] $label is not a contact, sending direct');
    } else {
      debugWarn('[SCOPES] Lookup for $label answered with code ${lf[0]}');
      return _localFailure('reply_owed', null);
    }

    if (contact == null && _host.cannotAskNonContacts) {
      debugLog('[SCOPES] $label is not a contact and this connection cannot '
          'ask non-contacts (contact table full), skipping the send');
      _end(_LeaseEnd.released);
      return const ScopeNonContactRefused();
    }

    // Borrow a zero-hop route unless it already has one.
    ContactRecord? borrowed;
    if (contact != null && !(contact.hasRoute && contact.routeHopCount == 0)) {
      if (!_active || _cancel.isCancelled) {
        return _stopped(_Ended(_endReason ?? _LeaseEnd.cancelled), null);
      }
      borrowed = contact;
      noteBorrow(contact);
      _addUnrestored(contact);
      debugLog('[SCOPES] Borrowing a zero-hop route to $label '
          '(out_path_len 0x${contact.outPathLen.toRadixString(16)})');
      final r = await _exchange(
          contact.withOutPathLen(0).toFrame(CommandCodes.addUpdateContact));
      if (r is! _Frame) return _stopped(r, borrowed);
      if (r.frame[0] != ResponseCodes.ok) {
        final isErr = r.frame[0] == ResponseCodes.err;
        final code = isErr && r.frame.length > 1 ? r.frame[1] : 0;
        debugWarn('[SCOPES] Borrow for $label answered with code '
            '${r.frame[0]}${isErr ? ' (error code $code)' : ''}');
        await _restore(borrowed);
        return isErr
            ? _radioError(code, borrowed)
            : _localFailure('reply_owed', borrowed);
      }
    }

    // Stage 2: send, and arm the answer tag inside the SENT dispatch.
    final answer = _host.armScopeAnswer();
    // The answer can land while the restore is still in flight; keep it so
    // an answer that beat its deadline is never thrown away.
    ScopeAnswerPush? received;
    unawaited(answer.then((a) => received = a, onError: (_) => null));
    int? estTimeoutMs;
    bool flood = false;
    DateTime? sentAt;
    final send = await _exchange(
        Uint8List.fromList([CommandCodes.sendAnonReq, ...pubkey, ...request]),
        onSync: (f) {
      if (f[0] != ResponseCodes.sent || f.length < 10) return;
      flood = f[1] != 0;
      estTimeoutMs = f[6] | (f[7] << 8) | (f[8] << 16) | (f[9] << 24);
      sentAt = clock.now();
      if (!flood) {
        _host.setScopeAnswerTag(Uint8List.fromList(f.sublist(2, 6)));
        _tagArmed = true;
      }
    });
    if (send is! _Frame) {
      _host.disarmScopeAnswer();
      return _stopped(send, borrowed);
    }
    final sf = send.frame;
    if (sf[0] != ResponseCodes.sent || estTimeoutMs == null) {
      _host.disarmScopeAnswer();
      final isErr = sf[0] == ResponseCodes.err;
      final code = isErr && sf.length > 1 ? sf[1] : 0;
      debugWarn('[SCOPES] Send to $label answered with code ${sf[0]}'
          '${isErr ? ' (error code $code)' : ''}');
      if (borrowed != null) await _restore(borrowed);
      if (isErr) {
        final nonContactTableFull = contact == null &&
            code == ErrorCodes.tableFull &&
            await _confirmContactNotAllocated(pubkey, label);
        if (nonContactTableFull) _host.markCannotAskNonContacts();
        return _radioError(code, borrowed,
            nonContactTableFull: nonContactTableFull);
      }
      return _localFailure(
          sf[0] == ResponseCodes.sent ? 'malformed_sent' : 'reply_owed',
          borrowed);
    }
    if (flood) {
      debugLog('[SCOPES] Request to $label was flooded, not waiting');
      _host.disarmScopeAnswer();
      if (borrowed != null) await _restore(borrowed);
      _end(_LeaseEnd.released);
      return ScopeFlooded(restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
    }
    if (!_active && _endReason != _LeaseEnd.holdCap) {
      // Cancelled or disconnected in the gap after SENT: no wait.
      return ScopeAborted(restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
    }

    var wait = answerWait ??
        Duration(milliseconds: estTimeoutMs!) + kScopeAnswerFallbackMargin;
    if (wait > kScopeAnswerWaitCap) wait = kScopeAnswerWaitCap;
    if (wait.isNegative) wait = Duration.zero;
    onSent?.call(wait);
    debugLog(
        '[SCOPES] Request to $label sent, waiting ${wait.inMilliseconds}ms '
        '(est ${estTimeoutMs}ms)');

    // The radio built and queued the packet inside the send command, so the
    // borrowed route can go back now, while the lease is still held.
    if (borrowed != null) await _restore(borrowed);

    // Stage 3: release the lease, then wait for the answer outside it.
    if (_active) {
      _end(_LeaseEnd.released, listen: true);
    } else if (_endReason != _LeaseEnd.holdCap) {
      // Cancelled or disconnected during the restore: no wait.
      return ScopeAborted(restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
    }
    // A deadline during the restore still hands the slot to the listen.

    var waitEnd = sentAt!.add(wait);
    if (notAfter.isBefore(waitEnd)) waitEnd = notAfter;
    final early = received;
    final Object result;
    if (early != null && !early.receivedAt.isAfter(waitEnd)) {
      result = early;
    } else {
      result = await _awaitAnswer(answer, waitEnd.difference(clock.now()));
    }
    _host.endListen();
    switch (result) {
      case ScopeAnswerPush(:final body, :final receivedAt):
        debugLog('[SCOPES] Answer from $label (${body.length} bytes)');
        return ScopeAnswered(body, receivedAt,
            restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
      case _LeaseEnd.cancelled || _LeaseEnd.disconnected:
        debugLog('[SCOPES] Answer wait for $label ended early');
        return ScopeAborted(
            restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
      default:
        debugLog('[SCOPES] No answer from $label');
        return ScopeNoAnswer(
            restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
    }
  }

  /// Waits for the tagged answer, the cancel token, a disconnect or
  /// [remaining]. Resolves with the push, or a [_LeaseEnd] (released means
  /// the wait ran out).
  Future<Object> _awaitAnswer(
      Future<ScopeAnswerPush> answer, Duration remaining) {
    if (_cancel.isCancelled) return Future.value(_LeaseEnd.cancelled);
    if (remaining <= Duration.zero) return Future.value(_LeaseEnd.released);
    final done = Completer<Object>();
    void settle(Object value) {
      if (!done.isCompleted) done.complete(value);
    }

    final timer = Timer(remaining, () => settle(_LeaseEnd.released));
    answer.then(settle, onError: (_) => settle(_LeaseEnd.disconnected));
    _cancel.whenCancelled.then((_) => settle(_LeaseEnd.cancelled));
    return done.future.whenComplete(timer.cancel);
  }

  /// Writes [original] back byte for byte. Resolves true when its OK
  /// arrives; otherwise the record stays in [unrestored] for a later lease.
  @override
  Future<bool> restore(ContactRecord original) async {
    if (!_active) return false;
    _addUnrestored(original);
    return _restore(original);
  }

  Future<bool> _restore(ContactRecord original) async {
    final r = await _exchange(original.toFrame(CommandCodes.addUpdateContact));
    final label = _prefix(original.publicKey);
    if (r is _Frame && r.frame[0] == ResponseCodes.ok) {
      _unrestored
          .removeWhere((c) => _sameBytes(c.publicKey, original.publicKey));
      debugLog('[SCOPES] Route to $label restored');
      return true;
    }
    final why = switch (r) {
      _Frame(:final frame) => 'answered with code ${frame[0]}',
      _Ended(:final why) => 'lease ended (${why.name})',
      _NotWritten(:final why) => 'not written ($why)',
      _WriteFailed(:final error) => 'write failed ($error)',
    };
    debugWarn('[SCOPES] Restore of $label pending: $why');
    return false;
  }

  /// Ends the lease now. Idempotent. A reply still owed stays in the
  /// connection's ledger until it arrives or expires.
  @override
  Future<void> release() async {
    _end(_LeaseEnd.released);
  }

  /// Connection use only: the link is going away. Settles any waiter with
  /// [ScopeAborted] and drops the unrestored records with the connection.
  void abortForDisconnect() {
    _unrestored.clear();
    _end(_LeaseEnd.disconnected);
  }

  // ---- internals ----

  /// Writes one command and waits for its reply. Never awaits the write
  /// itself: the deadline and the cancel token settle the wait without it.
  Future<_Reply> _exchange(Uint8List frame,
      {void Function(Uint8List frame)? onSync}) {
    if (!_active) return Future.value(_Ended(_endReason!));
    if (_cancel.isCancelled) {
      _end(_LeaseEnd.cancelled);
      return Future.value(const _Ended(_LeaseEnd.cancelled));
    }
    if (!_host.repliesSettled) {
      return Future.value(const _NotWritten('reply_owed'));
    }
    if (_deadline.difference(clock.now()) < kScopeLeaseMinCommandTime) {
      return Future.value(const _NotWritten('hold_cap'));
    }
    final pending = Completer<_Reply>();
    _pending = pending;
    _host.setLeaseReplyWaiter(this, (reply) {
      if (!identical(_pending, pending)) return;
      _pending = null;
      onSync?.call(reply);
      pending.complete(_Frame(reply));
    });
    _host.writeForLease(this, frame).then((_) {}, onError: (Object e) {
      if (!identical(_pending, pending)) return;
      _pending = null;
      _host.setLeaseReplyWaiter(this, null);
      debugWarn('[SCOPES] Lease write of command ${frame[0]} failed: $e');
      pending.complete(_WriteFailed(e));
    });
    return pending.future;
  }

  void _onDeadline() {
    if (!_active) return;
    debugWarn('[SCOPES] Lease hit its ${kScopeLeaseHold.inSeconds}s deadline, '
        'releasing');
    _end(_LeaseEnd.holdCap, listen: _tagArmed);
  }

  void _onCancel() {
    if (!_active) return;
    debugLog('[SCOPES] Lease cancelled, releasing');
    _end(_LeaseEnd.cancelled);
  }

  void _end(_LeaseEnd why, {bool listen = false}) {
    if (!_active) return;
    _active = false;
    _endReason = why;
    _deadlineTimer?.cancel();
    _deadlineTimer = null;
    final pending = _pending;
    _pending = null;
    _host.endLease(this, listen: listen);
    if (pending != null && !pending.isCompleted) pending.complete(_Ended(why));
  }

  /// The outcome for a stage that ended without its reply. Always leaves the
  /// lease released.
  ScopeRequestOutcome _stopped(_Reply r, ContactRecord? borrowed) {
    final ScopeRequestOutcome outcome;
    switch (r) {
      case _Ended(:final why):
        outcome = why == _LeaseEnd.holdCap
            ? ScopeLocalFailure('hold_cap',
                restoreOwed: _owes(borrowed), borrowedFrom: borrowed)
            : ScopeAborted(
                restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
      case _NotWritten(:final why):
        outcome = ScopeLocalFailure(why,
            restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
      case _WriteFailed():
        outcome = ScopeLocalFailure('write_failed',
            restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
      case _Frame():
        outcome = ScopeLocalFailure('reply_owed',
            restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
    }
    _end(_LeaseEnd.released);
    return outcome;
  }

  /// ERR_CODE_TABLE_FULL answers a non-contact's send for two different
  /// reasons the firmware does not distinguish: the anon contact could not
  /// be allocated (genuinely no free slot), or it WAS allocated and the send
  /// itself failed for an unrelated, transient reason (an empty packet
  /// pool: `BaseChatMesh::sendAnonReq` returns `MSG_SEND_FAILED` whenever its
  /// own packet allocation fails, whatever `recipient` was). One more lookup
  /// for the same key tells them apart, since `CMD_GET_CONTACT_BY_KEY` reads
  /// the very table `addContact` just inserted into: found means the slot
  /// exists, so this was not a table-full failure. True only when that
  /// lookup answers ERR_CODE_NOT_FOUND; false when it finds the contact,
  /// answers anything else, or there is no time left in the lease to even
  /// ask (the lease deadline and reply-ledger rules are [_exchange]'s own).
  Future<bool> _confirmContactNotAllocated(
      Uint8List pubkey, String label) async {
    final confirm = await _exchange(
        Uint8List.fromList([CommandCodes.getContactByKey, ...pubkey]));
    if (confirm is! _Frame) return false;
    final cf = confirm.frame;
    if (cf[0] == ResponseCodes.contact) {
      debugLog('[SCOPES] $label: the anon contact was allocated, so ERR 3 '
          'was a packet pool failure, not a full table');
      return false;
    }
    return cf[0] == ResponseCodes.err &&
        (cf.length > 1 ? cf[1] : 0) == ErrorCodes.notFound;
  }

  ScopeRequestOutcome _localFailure(String why, ContactRecord? borrowed) {
    _end(_LeaseEnd.released);
    return ScopeLocalFailure(why,
        restoreOwed: _owes(borrowed), borrowedFrom: borrowed);
  }

  ScopeRequestOutcome _radioError(int code, ContactRecord? borrowed,
      {bool nonContactTableFull = false}) {
    _end(_LeaseEnd.released);
    return ScopeRadioError(code,
        nonContactTableFull: nonContactTableFull,
        restoreOwed: _owes(borrowed),
        borrowedFrom: borrowed);
  }

  bool _owes(ContactRecord? borrowed) =>
      borrowed != null &&
      _unrestored.any((c) => _sameBytes(c.publicKey, borrowed.publicKey));

  void _addUnrestored(ContactRecord record) {
    if (_unrestored.any((c) => _sameBytes(c.publicKey, record.publicKey))) {
      return;
    }
    _unrestored.add(record);
  }

  static bool _sameBytes(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Public keys are logged as an 8-character prefix only.
  static String _prefix(Uint8List key) => key
      .take(4)
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join()
      .toUpperCase();
}
