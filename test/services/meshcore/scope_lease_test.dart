import 'dart:convert';
import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/meshcore/scope_lease.dart';

import 'scope_test_support.dart';

/// The radio lease for scope requests: the per-command reply ledger, the
/// contact stream state, admission, the lease gate and deadline, and the
/// answer wait outside the lease.
void main() {
  final key = scopeKey(0xAB);
  final request = Uint8List.fromList([0x01, 0x00]);
  final flood16 = Uint8List(16);

  Uint8List bytes(List<int> b) => Uint8List.fromList(b);

  ScopeRequestOutcome? Function() ask(FakeAsync async, ScopeLease lease,
      {Duration? answerWait = const Duration(seconds: 7), DateTime? notAfter}) {
    ScopeRequestOutcome? outcome;
    lease
        .requestScopes(key, request,
            answerWait: answerWait,
            notAfter: notAfter ?? clock.now().add(const Duration(seconds: 30)))
        .then((o) => outcome = o);
    async.flushMicrotasks();
    return () => outcome;
  }

  ContactRecord record(Uint8List payload) =>
      ContactRecord.parse(BufferReader(payload));

  group('reply shape', () {
    CommandReplyShape shape(List<int> frame) =>
        MeshCoreConnection.replyShapeOf(bytes(frame));

    test('a command earns one reply by default', () {
      final s = shape([CommandCodes.setFloodScope, 0, ...flood16]);
      expect(s.replies, 1);
      expect(s.selfTelemetry, isFalse);
      expect(s.opensContactStream, isFalse);
    });

    test('getContacts earns one initial reply and opens a stream', () {
      final s = shape([CommandCodes.getContacts, 0, 0, 0, 0]);
      expect(s.replies, 1);
      expect(s.opensContactStream, isTrue);
    });

    test('self telemetry (4 bytes) is answered by push 0x8B', () {
      final self = shape([CommandCodes.sendTelemetryReq, 0, 0, 0]);
      expect(self.replies, 1);
      expect(self.selfTelemetry, isTrue);
      final remote = shape([CommandCodes.sendTelemetryReq, 0, 0, 0, ...key]);
      expect(remote.replies, 1);
      expect(remote.selfTelemetry, isFalse);
    });

    test('reboot, factory reset and CLI reboot answer nothing', () {
      expect(shape([CommandCodes.reboot, ...utf8.encode('reboot')]).replies, 0);
      expect(shape([CommandCodes.reboot, ...utf8.encode('rebut!')]).replies, 1);
      expect(
          shape([CommandCodes.factoryReset, ...utf8.encode('reset')]).replies,
          0);
      expect(
          shape([CommandCodes.factoryReset, ...utf8.encode('nope!')]).replies,
          1);
      expect(
          shape([CommandCodes.runCliCommand, ...utf8.encode('reboot')]).replies,
          0);
      expect(
          shape([CommandCodes.runCliCommand, ...utf8.encode('01|reboot')])
              .replies,
          0);
      expect(
          shape([CommandCodes.runCliCommand, ...utf8.encode('get name')])
              .replies,
          1);
    });

    test('deviceQuery writes two commands and records two replies', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.deviceQuery(4).then((_) {}, onError: (_) {});
        async.flushMicrotasks();
        expect(
            radio.commands, [CommandCodes.deviceQuery, CommandCodes.appStart]);
        expect(conn.repliesOwedCount, 2);
        async.elapse(const Duration(seconds: 11));
      });
    });
  });

  group('reply ledger', () {
    test('a low frame retires the oldest entry, a push retires nothing', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.setFloodScope(flood16);
        conn.getBatteryVoltage();
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 2);
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 1);
        radio.emit([PushCodes.logRxData, 0, 0, 1, 2]);
        radio.emit([PushCodes.telemetryResponse, 0, 1, 2, 3, 4, 5, 6]);
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 1,
            reason: '0x8B is a reply only to a self-telemetry request');
        radio.emit([ResponseCodes.batteryVoltage, 0xA0, 0x0F]);
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 0);
      });
    });

    test('push 0x8B retires a self-telemetry entry', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.debugWriteRaw(bytes([CommandCodes.sendTelemetryReq, 0, 0, 0]));
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 1);
        radio.emit([PushCodes.telemetryResponse, 0, 1, 2, 3, 4, 5, 6]);
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 0);
      });
    });

    test('an entry expires 10 s after its write returns, never before', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.setFloodScope(flood16);
        async.flushMicrotasks();
        async.elapse(const Duration(milliseconds: 9999));
        expect(conn.repliesOwedCount, 1);
        async.elapse(const Duration(milliseconds: 1));
        expect(conn.repliesOwedCount, 0);

        // A write that never returns stays owed.
        radio.stallCommands.add(CommandCodes.setFloodScope);
        conn.setFloodScope(flood16);
        async.elapse(const Duration(seconds: 60));
        expect(conn.repliesOwedCount, 1);
        // Owed, but not to a scope lease: Manage does not wait for it.
        expect(conn.hasScopeReplyDebt, isFalse);
      });
    });

    test('a config write owed during a contact stream is not retired by END',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.debugWriteRaw(bytes([CommandCodes.getContacts, 0, 0, 0, 0]));
        conn.setFloodScope(flood16);
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 2);
        radio.emit([ResponseCodes.contactsStart, 1, 0, 0, 0]);
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 1, reason: 'START retires getContacts');
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        radio.emit([ResponseCodes.endOfContacts, 0, 0, 0, 0]);
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 1,
            reason: 'streamed CONTACT and END retire nothing');
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(conn.repliesOwedCount, 0);
      });
    });
  });

  group('contact stream', () {
    final getContacts = [CommandCodes.getContacts, 0, 0, 0, 0];

    test('requested, open, then none on END', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        expect(conn.contactsStreamState, ContactsStreamState.none);
        conn.debugWriteRaw(bytes(getContacts));
        async.flushMicrotasks();
        expect(conn.contactsStreamState, ContactsStreamState.requested);
        radio.emit([ResponseCodes.contactsStart, 0, 0, 0, 0]);
        async.flushMicrotasks();
        expect(conn.contactsStreamState, ContactsStreamState.open);
        radio.emit([ResponseCodes.endOfContacts, 0, 0, 0, 0]);
        async.flushMicrotasks();
        expect(conn.contactsStreamState, ContactsStreamState.none);
      });
    });

    test('a throwing write is ambiguous: the stream stays requested', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        // The transport cannot say whether a throw came before or after
        // sending, so even a throw before sending keeps the stream owed.
        radio.failWrites = true;
        conn.debugWriteRaw(bytes(getContacts)).then((_) {}, onError: (_) {});
        async.flushMicrotasks();
        expect(conn.contactsStreamState, ContactsStreamState.requested);
        // No frame ever comes: the silence rule suspends scope discovery.
        async.elapse(const Duration(seconds: 60));
        expect(conn.isScopeDiscoverySuspended, isTrue);
        expect(grant(async, conn, wait: const Duration(milliseconds: 200)),
            isNull);
      });
    });

    test(
        'a stream delivered before the write threw still opens and blocks '
        'the lease', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        radio.failAfterSend = true;
        Object? error;
        conn.debugWriteRaw(bytes(getContacts)).then((_) {},
            onError: (Object e) {
          error = e;
        });
        async.flushMicrotasks();
        radio.failAfterSend = false;
        expect(error, isA<StateError>());
        expect(conn.contactsStreamState, ContactsStreamState.requested);

        radio.emit([ResponseCodes.contactsStart, 2, 0, 0, 0]);
        async.flushMicrotasks();
        expect(conn.contactsStreamState, ContactsStreamState.open);
        expect(conn.repliesOwedCount, 0);
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        async.flushMicrotasks();
        // A lease attempt mid-stream is refused: a streamed CONTACT must
        // never be taken as a lookup reply.
        expect(grant(async, conn, wait: const Duration(milliseconds: 200)),
            isNull);
        expect(radio.writes.length, 1);
        radio.emit(contactFrame(scopeContactPayload(pubkey: scopeKey(0x22))));
        radio.emit([ResponseCodes.endOfContacts, 0, 0, 0, 0]);
        async.flushMicrotasks();
        expect(conn.contactsStreamState, ContactsStreamState.none);
        expect(grant(async, conn), isNotNull);
      });
    });

    test('none when the initial reply is ERR', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.debugWriteRaw(bytes(getContacts));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.badState]);
        async.flushMicrotasks();
        expect(conn.contactsStreamState, ContactsStreamState.none);
        expect(conn.repliesOwedCount, 0);
      });
    });

    test('none when an APP_START is written while open', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.debugWriteRaw(bytes(getContacts));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.contactsStart, 0, 0, 0, 0]);
        async.flushMicrotasks();
        conn.sendCommandAppStart();
        async.flushMicrotasks();
        expect(conn.contactsStreamState, ContactsStreamState.none);
      });
    });

    test('a stream silent for 60 s suspends scope discovery until reconnect',
        () {
      final lines = captureScopeLog();
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.debugWriteRaw(bytes(getContacts));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.contactsStart, 0, 0, 0, 0]);
        async.elapse(const Duration(seconds: 59));
        expect(conn.isScopeDiscoverySuspended, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(conn.isScopeDiscoverySuspended, isTrue);
        async.elapse(const Duration(seconds: 120));
        expect(grant(async, conn), isNull);
        expect(conn.contactsStreamState, ContactsStreamState.open,
            reason: 'not silently cleared');

        conn.disconnect();
        async.flushMicrotasks();
        expect(conn.isScopeDiscoverySuspended, isFalse);
      });
      expect(
          lines
              .where((l) =>
                  l.contains('[SCOPES]') &&
                  l.contains('suspended until reconnect'))
              .length,
          1);
      // A fresh connection object starts clean.
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        expect(grant(async, conn), isNotNull);
      });
    });
  });

  group('radio restart', () {
    for (final entry in <String, List<int>>{
      'reboot': [CommandCodes.reboot, ...utf8.encode('reboot')],
      'factory reset': [CommandCodes.factoryReset, ...utf8.encode('reset')],
      'CLI reboot': [CommandCodes.runCliCommand, ...utf8.encode('reboot')],
    }.entries) {
      test('after a ${entry.key} no lease is admitted until reconnect', () {
        final lines = captureScopeLog();
        onScopeClock(ScopeRadio.new, (async, radio, conn) {
          conn.debugWriteRaw(bytes(entry.value));
          async.flushMicrotasks();
          expect(conn.repliesOwedCount, 0);
          expect(conn.isScopeDiscoverySuspended, isTrue);
          expect(grant(async, conn), isNull);
          async.elapse(const Duration(seconds: 30));
          conn.disconnect();
          async.flushMicrotasks();
          expect(grant(async, conn), isNull,
              reason: 'only a new connection object clears it');
        });
        expect(
            lines.any((l) =>
                l.contains('[SCOPES] Lease not admitted') &&
                l.contains('reboot or reset')),
            isTrue);
        onScopeClock(ScopeRadio.new, (async, radio, conn) {
          expect(grant(async, conn), isNotNull);
        });
      });
    }

    test('reboot() blocks the lease', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.reboot();
        async.flushMicrotasks();
        expect(grant(async, conn), isNull);
      });
    });

    test('a reboot payload that is not the magic word blocks nothing', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.debugWriteRaw(
            bytes([CommandCodes.reboot, ...utf8.encode('rebut!')]));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.illegalArg]);
        async.flushMicrotasks();
        expect(grant(async, conn), isNotNull);
      });
    });
  });

  group('admission', () {
    test('a cancel (Stop) during the debt wait grants nothing', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.setFloodScope(flood16);
        final cancel = ScopeCancelToken();
        ScopeLease? lease;
        var done = false;
        conn
            .acquireScopeLease(
                admissionWait: const Duration(seconds: 3), cancel: cancel)
            .then((l) {
          lease = l;
          done = true;
        });
        async.elapse(const Duration(milliseconds: 200));
        expect(done, isFalse);
        cancel.cancel();
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(lease, isNull);
        radio.emit([ResponseCodes.ok]);
        async.elapse(const Duration(seconds: 1));
        expect(conn.isScopeLeaseActive, isFalse);

        // A replacement runner is admitted normally.
        expect(grant(async, conn), isNotNull);
      });
    });

    test('a hard stop during the poll drain grants nothing', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.getNoiseFloor().then((_) {}, onError: (_) {});
        async.flushMicrotasks();
        final cancel = ScopeCancelToken();
        ScopeLease? lease;
        var done = false;
        conn
            .acquireScopeLease(
                admissionWait: const Duration(seconds: 3), cancel: cancel)
            .then((l) {
          lease = l;
          done = true;
        });
        async.elapse(const Duration(milliseconds: 100));
        cancel.cancel();
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(lease, isNull);
        expect(conn.isScopeLeaseActive, isFalse);
      });
    });

    test('a disconnect during admission grants nothing', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.setFloodScope(flood16);
        ScopeLease? lease;
        var done = false;
        conn
            .acquireScopeLease(
                admissionWait: const Duration(seconds: 3),
                cancel: ScopeCancelToken())
            .then((l) {
          lease = l;
          done = true;
        });
        async.elapse(const Duration(milliseconds: 100));
        conn.disconnect();
        async.elapse(const Duration(milliseconds: 100));
        expect(done, isTrue);
        expect(lease, isNull);
      });
    });

    test('a lease handed to an already cancelled runner is released at once',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final cancel = ScopeCancelToken();
        final lease = grant(async, conn, cancel: cancel)!;
        conn.setFloodScope(flood16);
        async.flushMicrotasks();
        expect(radio.writes, isEmpty, reason: 'parked at the lease gate');
        cancel.cancel();
        async.flushMicrotasks();
        expect(lease.active, isFalse);
        expect(radio.commands, [CommandCodes.setFloodScope]);
      });
    });

    test('refused while a sign is in progress', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.sign(Uint8List(32)).then((_) {}, onError: (_) {});
        async.flushMicrotasks();
        expect(grant(async, conn, wait: const Duration(milliseconds: 200)),
            isNull);
        async.elapse(const Duration(seconds: 6));
      });
    });

    test('refused while a contact stream is open', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.debugWriteRaw(bytes([CommandCodes.getContacts, 0, 0, 0, 0]));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.contactsStart, 0, 0, 0, 0]);
        async.flushMicrotasks();
        expect(grant(async, conn, wait: const Duration(milliseconds: 200)),
            isNull);
      });
    });

    test('waits out an owed config OK, then grants', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        // A session recovery's setFloodScope written just before.
        conn.setFloodScope(flood16);
        ScopeLease? lease;
        conn
            .acquireScopeLease(
                admissionWait: const Duration(seconds: 3),
                cancel: ScopeCancelToken())
            .then((l) => lease = l);
        async.elapse(const Duration(milliseconds: 500));
        expect(lease, isNull);
        expect(conn.isScopeLeaseActive, isFalse);
        radio.emit([ResponseCodes.ok]);
        async.elapse(const Duration(milliseconds: 100));
        expect(lease, isNotNull);
        expect(lease!.active, isTrue);
      });
    });

    test('refused while the admin slot is owned', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.login(key, 'pw').then((_) {}, onError: (_) {});
        async.flushMicrotasks();
        radio.emit(sentFrame());
        async.flushMicrotasks();
        expect(conn.hasPendingAdminCommand, isTrue);
        expect(grant(async, conn, wait: const Duration(milliseconds: 200)),
            isNull);
        async.elapse(const Duration(seconds: 30));
      });
    });

    test('a poll in flight is drained first', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.getNoiseFloor().then((_) {}, onError: (_) {});
        async.flushMicrotasks();
        ScopeLease? lease;
        conn
            .acquireScopeLease(
                admissionWait: const Duration(seconds: 3),
                cancel: ScopeCancelToken())
            .then((l) => lease = l);
        async.elapse(const Duration(milliseconds: 300));
        expect(lease, isNull);
        radio.emit([
          ResponseCodes.stats,
          StatsTypes.radio,
          0x90,
          0xFF,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0,
          0
        ]);
        async.elapse(const Duration(milliseconds: 100));
        expect(lease, isNotNull);
      });
    });
  });

  group('while held', () {
    test('a config write waits at the gate and goes out after release', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final lease = grant(async, conn)!;
        conn.setFloodScope(flood16);
        async.elapse(const Duration(seconds: 1));
        expect(radio.writes, isEmpty);
        expect(conn.repliesOwedCount, 0,
            reason: 'no config write is on the wire while the lease holds');
        lease.release();
        async.flushMicrotasks();
        expect(radio.commands, [CommandCodes.setFloodScope]);
      });
    });

    test('pollers skip while the lease is held and run during the answer wait',
        () {
      onScopeClock(PollingScopeRadio.new, (async, radio, conn) {
        conn.connect((_) async => null);
        async.elapse(const Duration(seconds: 5));
        final before = radio.count(CommandCodes.getStats);
        final lease = grant(async, conn)!;
        final outcome = ask(async, lease);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.elapse(const Duration(seconds: 1));
        expect(lease.active, isTrue);
        expect(radio.count(CommandCodes.getStats), before,
            reason: 'the 5 s poll tick fell inside the lease');
        radio.emit(sentFrame());
        async.flushMicrotasks();
        expect(conn.isScopeListenActive, isTrue);
        async.elapse(const Duration(seconds: 5));
        expect(radio.count(CommandCodes.getStats), before + 1);
        expect(conn.isScopeListenActive, isTrue);
        radio.emit(answerPush());
        async.flushMicrotasks();
        expect(outcome(), isA<ScopeAnswered>());
      });
    });
  });

  group('lease deadline', () {
    /// Starts an ask with a TX queued behind the lease; returns the outcome
    /// getter, the lease and when it was granted.
    ({
      ScopeRequestOutcome? Function() outcome,
      ScopeLease lease,
      DateTime granted
    }) start(FakeAsync async, ScopeRadio radio, MeshCoreConnection conn) {
      final lease = grant(async, conn)!;
      final granted = clock.now();
      final outcome = ask(async, lease);
      conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) {});
      async.flushMicrotasks();
      return (outcome: outcome, lease: lease, granted: granted);
    }

    void expectReleasedAtFourSeconds(FakeAsync async, ScopeRadio radio,
        MeshCoreConnection conn, ScopeLease lease, DateTime granted) {
      final left =
          granted.add(const Duration(seconds: 4)).difference(clock.now());
      async.elapse(left - const Duration(milliseconds: 1));
      expect(lease.active, isTrue);
      expect(radio.commands.contains(CommandCodes.sendChannelTxtMsg), isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(lease.active, isFalse);
      expect(radio.commands.last, CommandCodes.sendChannelTxtMsg,
          reason: 'the queued TX goes out once the lease releases');
    }

    test('a missing borrow OK ends the lease at 4 s', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final s = start(async, radio, conn);
        final payload = scopeContactPayload(pubkey: key);
        radio.emit(contactFrame(payload));
        async.flushMicrotasks();
        expect(radio.commands.last, CommandCodes.addUpdateContact);
        expectReleasedAtFourSeconds(async, radio, conn, s.lease, s.granted);
        expect((s.outcome()! as ScopeLocalFailure).why, 'hold_cap');
        expect(s.outcome()!.restoreOwed, isTrue);
        expect(s.lease.unrestored.single.publicKey, key);
      });
    });

    test('a missing SENT ends the lease at 4 s', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final s = start(async, radio, conn);
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(radio.commands.last, CommandCodes.sendAnonReq);
        expectReleasedAtFourSeconds(async, radio, conn, s.lease, s.granted);
        expect((s.outcome()! as ScopeLocalFailure).why, 'hold_cap');
        expect(s.lease.unrestored, hasLength(1));
        expect(conn.hasPendingAdminCommand, isFalse);
      });
    });

    test('a missing restore OK ends the lease at 4 s and still listens', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final s = start(async, radio, conn);
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        radio.emit(sentFrame());
        async.flushMicrotasks();
        expect(radio.commands.last, CommandCodes.addUpdateContact);
        expectReleasedAtFourSeconds(async, radio, conn, s.lease, s.granted);
        expect(conn.isScopeListenActive, isTrue);
        radio.emit(answerPush());
        async.flushMicrotasks();
        expect(s.outcome(), isA<ScopeAnswered>());
        expect(s.outcome()!.restoreOwed, isTrue);
        expect(s.lease.unrestored, hasLength(1));
      });
    });

    test('a stalled write ends the lease at 4 s without awaiting it', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        radio.stallCommands.add(CommandCodes.addUpdateContact);
        final s = start(async, radio, conn);
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        async.flushMicrotasks();
        expectReleasedAtFourSeconds(async, radio, conn, s.lease, s.granted);
        expect((s.outcome()! as ScopeLocalFailure).why, 'hold_cap');
        expect(s.lease.unrestored, hasLength(1));
        expect(conn.hasScopeReplyDebt, isTrue,
            reason: 'the stalled write stays owed');
      });
    });
  });

  group('background traffic', () {
    test('a TX written during the lease goes out right after release', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final lease = grant(async, conn)!;
        conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) {});
        async.elapse(const Duration(milliseconds: 500));
        expect(radio.writes, isEmpty);
        lease.release();
        async.flushMicrotasks();
        expect(radio.commands, [CommandCodes.sendChannelTxtMsg]);
      });
    });

    test(
        'TX and discovery go out during the answer wait; their OKs are not the answer',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final outcome = ask(async, grant(async, conn)!);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit(sentFrame());
        async.flushMicrotasks();
        var txDone = false;
        conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) => txDone = true);
        conn.sendDiscoveryRequest();
        async.flushMicrotasks();
        expect(radio.commands.sublist(2),
            [CommandCodes.sendChannelTxtMsg, CommandCodes.sendControlData]);
        radio.emit([ResponseCodes.ok]);
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(txDone, isTrue);
        expect(outcome(), isNull);
        radio.emit(answerPush());
        async.flushMicrotasks();
        expect(outcome(), isA<ScopeAnswered>());
      });
    });

    test(
        'login and binary requests are refused while the listen holds the slot',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        ask(async, grant(async, conn)!);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit(sentFrame());
        async.flushMicrotasks();
        expect(conn.hasPendingAdminCommand, isTrue);
        Object? loginError;
        Object? binaryError;
        conn.login(key, 'pw').then((_) {}, onError: (Object e) {
          loginError = e;
        });
        conn.sendBinaryRequest(key, bytes([5, 0, 0])).then((_) {},
            onError: (Object e) {
          binaryError = e;
        });
        async.flushMicrotasks();
        expect(loginError, isA<StateError>());
        expect(binaryError, isA<StateError>());
        async.elapse(const Duration(seconds: 8));
      });
    });

    void expectWait(Duration? answerWait, int est, Duration expected,
        {Duration? notAfterIn}) {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        Duration? reported;
        ScopeRequestOutcome? outcome;
        grant(async, conn)!
            .requestScopes(key, request,
                answerWait: answerWait,
                notAfter:
                    clock.now().add(notAfterIn ?? const Duration(seconds: 60)),
                onSent: (w) => reported = w)
            .then((o) => outcome = o);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit(sentFrame(est: est));
        async.flushMicrotasks();
        if (notAfterIn == null) expect(reported, expected);
        async.elapse(expected - const Duration(milliseconds: 1));
        expect(outcome, isNull);
        async.elapse(const Duration(milliseconds: 1));
        expect(outcome, isA<ScopeNoAnswer>());
      });
    }

    test('the answer wait is the given answerWait', () {
      expectWait(const Duration(seconds: 3), 1500, const Duration(seconds: 3));
    });

    test('without answerWait it is est_timeout plus 1 s', () {
      expectWait(null, 1500, const Duration(milliseconds: 2500));
    });

    test('the answer wait never exceeds 7 s', () {
      expectWait(const Duration(seconds: 10), 1500, const Duration(seconds: 7));
      expectWait(null, 9000, const Duration(seconds: 7));
    });

    test('the answer wait is cut at notAfter', () {
      expectWait(const Duration(seconds: 7), 1500, const Duration(seconds: 1),
          notAfterIn: const Duration(seconds: 1));
    });
  });

  group('late replies', () {
    test(
        'a borrow OK after the deadline is retired before the restore is written',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final first = grant(async, conn)!;
        final payload = scopeContactPayload(pubkey: key);
        final outcome = ask(async, first);
        radio.emit(contactFrame(payload));
        async.elapse(const Duration(seconds: 4));
        expect(outcome(), isA<ScopeLocalFailure>());
        final owed = first.unrestored.single;

        ScopeLease? second;
        conn
            .acquireScopeLease(
                admissionWait: const Duration(seconds: 3),
                cancel: ScopeCancelToken())
            .then((l) => second = l);
        async.elapse(const Duration(milliseconds: 500));
        expect(second, isNull, reason: 'the borrow OK is still owed');
        radio.emit([ResponseCodes.ok]);
        async.elapse(const Duration(milliseconds: 100));
        expect(second, isNotNull);
        final writesBefore = radio.writes.length;
        bool? restored;
        second!.restore(owed).then((r) => restored = r);
        async.flushMicrotasks();
        expect(radio.writes.length, writesBefore + 1);
        expect(radio.writes.last, [CommandCodes.addUpdateContact, ...payload]);
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(restored, isTrue);
        expect(second!.unrestored, isEmpty);
      });
    });

    test('after a SENT timeout a late ERR is retired before the restore', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final first = grant(async, conn)!;
        ask(async, first);
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.ok]);
        async.elapse(const Duration(seconds: 4));
        expect(first.active, isFalse);
        expect(conn.hasScopeReplyDebt, isTrue);

        ScopeLease? second;
        conn
            .acquireScopeLease(
                admissionWait: const Duration(seconds: 3),
                cancel: ScopeCancelToken())
            .then((l) => second = l);
        async.elapse(const Duration(milliseconds: 500));
        expect(second, isNull);
        radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
        async.elapse(const Duration(milliseconds: 100));
        expect(second, isNotNull);
        second!.restore(first.unrestored.single);
        async.flushMicrotasks();
        expect(radio.commands.last, CommandCodes.addUpdateContact);
      });
    });
  });

  group('reply expiry', () {
    /// A first request whose lookup is never answered: the lease ends at
    /// 4 s and the lookup's owed reply expires unanswered at 10 s.
    void expireAnUnansweredLookup(
        FakeAsync async, ScopeRadio radio, MeshCoreConnection conn) {
      final first = grant(async, conn)!;
      ask(async, first);
      expect(radio.commands.last, CommandCodes.getContactByKey);
      async.elapse(const Duration(seconds: 4));
      expect(first.active, isFalse);
      expect(conn.hasScopeReplyDebt, isTrue);
      async.elapse(const Duration(seconds: 7));
      expect(conn.hasScopeReplyDebt, isFalse,
          reason: 'the lookup reply expired unanswered');
    }

    int anonRequests(ScopeRadio radio) =>
        radio.commands.where((c) => c == CommandCodes.sendAnonReq).length;

    test(
        'an old lookup ERR_NOT_FOUND after its debt expired never sends to a '
        'saved flood-route contact', () {
      final lines = captureScopeLog();
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        expireAnUnansweredLookup(async, radio, conn);
        expect(conn.isScopeDiscoverySuspended, isTrue);

        final second = grant(async, conn);
        if (second != null) {
          ask(async, second);
          // The old lookup's late ERR_NOT_FOUND, then the new lookup's real
          // CONTACT (a saved contact with no route), then its SENT.
          radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
          async.flushMicrotasks();
          radio.emit(contactFrame(scopeContactPayload(
              pubkey: key, outPathLen: 0xFF, outPath: const [])));
          radio.emit(sentFrame(flood: true));
          async.elapse(const Duration(seconds: 5));
        }
        expect(anonRequests(radio), 0,
            reason: 'command 57 must never be written');
        expect(second, isNull);
        async.elapse(const Duration(minutes: 2));
        expect(grant(async, conn), isNull,
            reason: 'suspended for the rest of the connection');
      });
      expect(
          lines
              .where((l) =>
                  l.contains('[SCOPES]') && l.contains('out of step'))
              .length,
          1);
      // A new connection object starts in step.
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        expect(grant(async, conn), isNotNull);
      });
    });

    test(
        'a stale zero-hop CONTACT after the debt expired is never taken as '
        'the new lookup answer', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        expireAnUnansweredLookup(async, radio, conn);

        final second = grant(async, conn);
        if (second != null) {
          ask(async, second);
          // The old lookup's CONTACT (zero hop at the time), though the
          // radio's route is now 0xFF: the lease would skip the borrow.
          radio.emit(contactFrame(
              scopeContactPayload(pubkey: key, outPathLen: 0, outPath: const [])));
          async.flushMicrotasks();
          radio.emit(contactFrame(scopeContactPayload(
              pubkey: key, outPathLen: 0xFF, outPath: const [])));
          radio.emit(sentFrame(flood: true));
          async.elapse(const Duration(seconds: 5));
        }
        expect(anonRequests(radio), 0,
            reason: 'command 57 must never be written');
        expect(second, isNull);
      });
    });

    test('a lease waiting out the debt is refused once it expires', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.setFloodScope(flood16);
        async.flushMicrotasks();
        ScopeLease? lease;
        var done = false;
        conn
            .acquireScopeLease(
                admissionWait: const Duration(seconds: 15),
                cancel: ScopeCancelToken())
            .then((l) {
          lease = l;
          done = true;
        });
        async.elapse(const Duration(seconds: 11));
        expect(done, isTrue);
        expect(lease, isNull);
      });
    });

    test('a debt answered in time leaves scope work running', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        conn.setFloodScope(flood16);
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 9));
        radio.emit([ResponseCodes.ok]);
        async.elapse(const Duration(seconds: 30));
        expect(conn.isScopeDiscoverySuspended, isFalse);
        expect(grant(async, conn), isNotNull);
      });
    });
  });

  group('cancellation', () {
    test('a cancel before the borrow write puts no further byte on the air',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final cancel = ScopeCancelToken();
        final outcome = ask(async, grant(async, conn, cancel: cancel)!);
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        cancel.cancel();
        async.elapse(const Duration(seconds: 10));
        expect(radio.commands, [CommandCodes.getContactByKey]);
        expect(outcome(), isA<ScopeAborted>());
      });
    });

    test('a cancel during a stalled borrow writes nothing more', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        radio.stallCommands.add(CommandCodes.addUpdateContact);
        final cancel = ScopeCancelToken();
        final lease = grant(async, conn, cancel: cancel)!;
        final outcome = ask(async, lease);
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        async.flushMicrotasks();
        cancel.cancel();
        async.elapse(const Duration(seconds: 10));
        expect(radio.commands,
            [CommandCodes.getContactByKey, CommandCodes.addUpdateContact]);
        expect(outcome(), isA<ScopeAborted>());
        expect(lease.active, isFalse);
        expect(lease.unrestored, hasLength(1));
      });
    });

    test(
        'a cancel after the borrow leaves the record; the next lease restores it first',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final payload = scopeContactPayload(pubkey: key);
        final cancel = ScopeCancelToken();
        final first = grant(async, conn, cancel: cancel)!;
        final outcome = ask(async, first);
        radio.emit(contactFrame(payload));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(radio.commands.last, CommandCodes.sendAnonReq);
        cancel.cancel();
        async.flushMicrotasks();
        expect(outcome(), isA<ScopeAborted>());
        expect(outcome()!.restoreOwed, isTrue);
        final owed = first.unrestored.single;
        expect(owed.toFrame(CommandCodes.addUpdateContact),
            [CommandCodes.addUpdateContact, ...payload]);

        // The late SENT is retired, then the next lease restores first.
        radio.emit(sentFrame());
        async.flushMicrotasks();
        final second = grant(async, conn)!;
        second.restore(owed);
        async.flushMicrotasks();
        expect(radio.writes.last, [CommandCodes.addUpdateContact, ...payload]);
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(second.unrestored, isEmpty);
        expect(record(payload).publicKey, key);
      });
    });

    test('a disconnect aborts the request and drops everything', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final lease = grant(async, conn)!;
        final outcome = ask(async, lease);
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        conn.disconnect();
        async.flushMicrotasks();
        expect(outcome(), isA<ScopeAborted>());
        expect(lease.active, isFalse);
        expect(lease.unrestored, isEmpty);
        expect(conn.isScopeLeaseActive, isFalse);
        expect(conn.hasScopeReplyDebt, isFalse);
        expect(conn.hasPendingAdminCommand, isFalse);
      });
    });

    test('a disconnect during the answer wait is ScopeAborted', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final outcome = ask(async, grant(async, conn)!);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit(sentFrame());
        async.flushMicrotasks();
        expect(conn.isScopeListenActive, isTrue);
        conn.disconnect();
        async.flushMicrotasks();
        expect(outcome(), isA<ScopeAborted>());
        expect(conn.isScopeListenActive, isFalse);
      });
    });
  });

  group('contact table full', () {
    test('a new connection object starts with the flag clear', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        ask(async, grant(async, conn)!);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        expect(conn.scopeCannotAskNonContacts, isTrue);
      });
      // A fresh connection object (a reconnect) starts clean, even though
      // the previous connection's flag was set.
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        expect(conn.scopeCannotAskNonContacts, isFalse);
      });
    });
  });

  group('release', () {
    test(
        'a reply owed at release is retired on arrival and dispatched as before',
        () {
      final lines = captureScopeLog();
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final lease = grant(async, conn)!;
        lease.restore(record(scopeContactPayload(pubkey: key)));
        async.elapse(const Duration(seconds: 4));
        expect(lease.active, isFalse);
        expect(conn.hasScopeReplyDebt, isTrue);
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(conn.hasScopeReplyDebt, isFalse);
      });
      expect(
          lines.any((l) => l.contains('[CONN] Received OK response')), isTrue);
    });

    test('queued writes go out in their original order', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final lease = grant(async, conn)!;
        conn.setFloodScope(flood16);
        conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) {});
        conn.sendDiscoveryRequest();
        conn.getBatteryVoltage();
        async.flushMicrotasks();
        expect(radio.writes, isEmpty);
        lease.release();
        async.flushMicrotasks();
        expect(radio.commands, [
          CommandCodes.setFloodScope,
          CommandCodes.sendChannelTxtMsg,
          CommandCodes.sendControlData,
          CommandCodes.getBatteryVoltage,
        ]);
        async.elapse(const Duration(seconds: 11));
      });
    });
  });
}
