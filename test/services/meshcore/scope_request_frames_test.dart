import 'dart:typed_data';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/meshcore/scope_lease.dart';

import 'scope_test_support.dart';

/// Byte vectors for the scope request, from examples/companion_radio/MyMesh.cpp
/// (CMD_GET_CONTACT_BY_KEY, CMD_ADD_UPDATE_CONTACT, CMD_SEND_ANON_REQ and
/// writeContactRespFrame).
void main() {
  final key = scopeKey(0xAB);
  final request = Uint8List.fromList([0x01, 0x00]);

  /// Starts a request on a fresh lease; [out] receives the outcome.
  void ask(FakeAsync async, MeshCoreConnection conn,
      void Function(ScopeRequestOutcome) out,
      {Duration? answerWait = const Duration(seconds: 7),
      DateTime? notAfter,
      void Function(Duration)? onSent}) {
    final lease = grant(async, conn)!;
    lease
        .requestScopes(key, request,
            answerWait: answerWait,
            notAfter: notAfter ?? clock.now().add(const Duration(seconds: 30)),
            onSent: onSent)
        .then(out);
    async.flushMicrotasks();
  }

  test('lookup, borrow, send and restore go out byte for byte', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      // A name with invalid UTF-8 and junk after its NUL must survive.
      final raw = rawNameBytes([0x48, 0xFF, 0xC3, 0x69], after: [0x5A, 0x5A]);
      final payload =
          scopeContactPayload(pubkey: key, rawName: raw, lastMod: 0x01020304);
      ScopeRequestOutcome? outcome;
      Duration? sentWait;
      ask(async, conn, (o) => outcome = o, onSent: (w) => sentWait = w);

      expect(radio.writes.last, [CommandCodes.getContactByKey, ...key]);
      radio.emit(contactFrame(payload));
      async.flushMicrotasks();

      // The borrow is the record as read with ONLY out_path_len changed.
      final borrow = radio.writes.last;
      expect(borrow[0], CommandCodes.addUpdateContact);
      expect(borrow.length, 1 + ContactRecord.payloadLength);
      final diffs = [
        for (var i = 0; i < payload.length; i++)
          if (borrow[i + 1] != payload[i]) i
      ];
      expect(diffs, [34], reason: 'only out_path_len (offset 34) may differ');
      expect(borrow[35], 0);

      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(radio.writes.last, [CommandCodes.sendAnonReq, ...key, 0x01, 0x00]);

      radio.emit(sentFrame(est: 1500));
      async.flushMicrotasks();
      expect(sentWait, const Duration(seconds: 7));
      // The restore is the lookup payload, byte for byte.
      expect(radio.writes.last, [CommandCodes.addUpdateContact, ...payload]);
      expect(conn.isScopeLeaseActive, isTrue,
          reason: 'held until the restore OK');

      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(conn.isScopeLeaseActive, isFalse);
      expect(conn.isScopeListenActive, isTrue);

      radio.emit(answerPush(body: [1, 0, 0, 0, 0x41, 0x2C, 0x42]));
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      final answered = outcome! as ScopeAnswered;
      expect(answered.body, [1, 0, 0, 0, 0x41, 0x2C, 0x42]);
      expect(answered.restoreOwed, isFalse);
      expect(answered.borrowedFrom?.publicKey, key);
      expect(conn.isScopeListenActive, isFalse);
      expect(conn.hasPendingAdminCommand, isFalse);
    });
  });

  test('an answer that lands during a slow restore is kept', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final payload = scopeContactPayload(pubkey: key);
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o,
          answerWait: const Duration(seconds: 1));
      radio.emit(contactFrame(payload));
      async.flushMicrotasks();
      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      final sentAt = clock.now();
      radio.emit(sentFrame());
      async.flushMicrotasks();
      expect(radio.writes.last, [CommandCodes.addUpdateContact, ...payload]);
      // The answer arrives 0.2 s after SENT, inside its 1 s wait ...
      async.elapse(const Duration(milliseconds: 200));
      radio.emit(answerPush(body: [0, 0, 0, 0, 0x41]));
      async.flushMicrotasks();
      // ... and the restore OK only at 2 s, after the answer wait ran out.
      async.elapse(const Duration(milliseconds: 1800));
      expect(outcome, isNull);
      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      final answered = outcome! as ScopeAnswered;
      expect(answered.body, [0, 0, 0, 0, 0x41]);
      expect(
          answered.receivedAt, sentAt.add(const Duration(milliseconds: 200)));
      expect(answered.restoreOwed, isFalse);
      expect(conn.isScopeListenActive, isFalse);
    });
  });

  test('a contact the radio does not know (ERR 2) goes straight to the send',
      () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      expect(radio.commands,
          [CommandCodes.getContactByKey, CommandCodes.sendAnonReq]);
      radio.emit(sentFrame());
      async.flushMicrotasks();
      expect(conn.isScopeLeaseActive, isFalse, reason: 'nothing to restore');
      radio.emit(answerPush());
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      expect(outcome!.borrowedFrom, isNull);
      expect(outcome!.restoreOwed, isFalse);
    });
  });

  test('an already zero-hop contact is not borrowed', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit(contactFrame(
          scopeContactPayload(pubkey: key, outPathLen: 0x80, outPath: [])));
      async.flushMicrotasks();
      expect(radio.commands,
          [CommandCodes.getContactByKey, CommandCodes.sendAnonReq]);
      radio.emit(sentFrame());
      radio.emit(answerPush());
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      expect(outcome!.borrowedFrom, isNull);
    });
  });

  test('a CONTACT for another key is reply_owed, not accepted', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit(contactFrame(scopeContactPayload(pubkey: scopeKey(0x11))));
      async.flushMicrotasks();
      expect(outcome, isA<ScopeLocalFailure>());
      expect((outcome! as ScopeLocalFailure).why, 'reply_owed');
      expect(radio.commands, [CommandCodes.getContactByKey]);
      expect(conn.isScopeLeaseActive, isFalse);
    });
  });

  test('SENT and the answer in the same transport chunk still answer', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      final start = clock.now();
      radio.emit(sentFrame(tag: [7, 7, 7, 7]));
      radio.emit(answerPush(tag: [7, 7, 7, 7], body: [0, 0, 0, 0]));
      async.flushMicrotasks();
      expect(outcome, isA<ScopeAnswered>());
      expect((outcome! as ScopeAnswered).receivedAt, start);
    });
  });

  test('an answer for another tag is ignored and the wait ends as no answer',
      () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      radio.emit(sentFrame(tag: [1, 1, 1, 1]));
      radio.emit(answerPush(tag: [2, 2, 2, 2]));
      async.elapse(const Duration(milliseconds: 6999));
      expect(outcome, isNull);
      async.elapse(const Duration(milliseconds: 1));
      expect(outcome, isA<ScopeNoAnswer>());
      // The tag is cleared: a late answer is ignored.
      radio.emit(answerPush(tag: [1, 1, 1, 1]));
      async.flushMicrotasks();
      expect(conn.isScopeListenActive, isFalse);
    });
  });

  test('a flooded send is ScopeFlooded at once', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      var sentCalled = false;
      ask(async, conn, (o) => outcome = o, onSent: (_) => sentCalled = true);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      radio.emit(sentFrame(flood: true));
      async.flushMicrotasks();
      expect(outcome, isA<ScopeFlooded>());
      expect(sentCalled, isFalse);
      expect(conn.hasPendingAdminCommand, isFalse);
    });
  });

  test('a malformed SENT is malformed_sent and the borrow is restored', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final payload = scopeContactPayload(pubkey: key);
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit(contactFrame(payload));
      async.flushMicrotasks();
      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      radio.emit([ResponseCodes.sent, 0, 1, 2]);
      async.flushMicrotasks();
      expect(radio.writes.last, [CommandCodes.addUpdateContact, ...payload]);
      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(outcome, isA<ScopeLocalFailure>());
      expect((outcome! as ScopeLocalFailure).why, 'malformed_sent');
      expect(outcome!.restoreOwed, isFalse);
    });
  });

  test('a throwing write is write_failed', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      final lease = grant(async, conn)!;
      radio.failWrites = true;
      ScopeRequestOutcome? outcome;
      lease
          .requestScopes(key, request,
              answerWait: null,
              notAfter: clock.now().add(const Duration(seconds: 30)))
          .then((o) => outcome = o);
      async.flushMicrotasks();
      expect(outcome, isA<ScopeLocalFailure>());
      expect((outcome! as ScopeLocalFailure).why, 'write_failed');
      expect(lease.active, isFalse);
    });
  });

  test('an ERR other than 2 is ScopeRadioError', () {
    onScopeClock(ScopeRadio.new, (async, radio, conn) {
      ScopeRequestOutcome? outcome;
      ask(async, conn, (o) => outcome = o);
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
      async.flushMicrotasks();
      // The ambiguous ERR 3 on a non-contact send is confirmed with one more
      // lookup before the outcome lands; answer it not-found here so this
      // generic test does not hang on an unanswered exchange.
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      expect(outcome, isA<ScopeRadioError>());
      expect((outcome! as ScopeRadioError).code, ErrorCodes.tableFull);
    });
  });

  group('a full contact table', () {
    test('a table-full send to a non-contact, confirmed still absent, sets '
        'the connection flag and marks the outcome', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        expect(conn.scopeCannotAskNonContacts, isFalse);
        ScopeRequestOutcome? outcome;
        ask(async, conn, (o) => outcome = o);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
        async.flushMicrotasks();
        // The confirming re-lookup: still not a contact, so the anon
        // contact really could not be allocated.
        expect(radio.commands.last, CommandCodes.getContactByKey);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        expect(outcome, isA<ScopeRadioError>());
        final err = outcome! as ScopeRadioError;
        expect(err.code, ErrorCodes.tableFull);
        expect(err.nonContactTableFull, isTrue);
        expect(conn.scopeCannotAskNonContacts, isTrue);
        expect(radio.commands, [
          CommandCodes.getContactByKey,
          CommandCodes.sendAnonReq,
          CommandCodes.getContactByKey,
        ]);
      });
    });

    test('a table-full send to a non-contact, but the re-lookup now finds '
        'it, never sets the flag (the packet pool was full, not the table)',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        ScopeRequestOutcome? outcome;
        ask(async, conn, (o) => outcome = o);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
        async.flushMicrotasks();
        expect(radio.commands.last, CommandCodes.getContactByKey);
        // The confirming re-lookup: the anon contact WAS allocated after
        // all, so `addContact` succeeded and `sendAnonReq` itself failed
        // for an unrelated (transient) reason.
        radio.emit(contactFrame(scopeContactPayload(pubkey: key)));
        async.flushMicrotasks();
        expect(outcome, isA<ScopeRadioError>());
        final err = outcome! as ScopeRadioError;
        expect(err.code, ErrorCodes.tableFull);
        expect(err.nonContactTableFull, isFalse);
        expect(conn.scopeCannotAskNonContacts, isFalse);
      });
    });

    test('a table-full send to a SAVED contact never sets the flag', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final payload = scopeContactPayload(pubkey: key);
        ScopeRequestOutcome? outcome;
        ask(async, conn, (o) => outcome = o);
        radio.emit(contactFrame(payload));
        async.flushMicrotasks();
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
        async.flushMicrotasks();
        // The ERR still owes the borrow's restore before the outcome lands.
        expect(radio.commands.last, CommandCodes.addUpdateContact);
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        expect(outcome, isA<ScopeRadioError>());
        final err = outcome! as ScopeRadioError;
        expect(err.code, ErrorCodes.tableFull);
        expect(err.nonContactTableFull, isFalse);
        expect(conn.scopeCannotAskNonContacts, isFalse);
      });
    });

    test(
        'once the flag is set, a fresh non-contact lookup ends the ask '
        'without a send', () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        ask(async, conn, (_) {});
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        expect(conn.scopeCannotAskNonContacts, isTrue);

        final before = radio.commands.length;
        ScopeRequestOutcome? outcome;
        ask(async, conn, (o) => outcome = o);
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        expect(outcome, isA<ScopeNonContactRefused>());
        expect(radio.commands.sublist(before), [CommandCodes.getContactByKey],
            reason: 'the lookup happens, but nothing is sent');
        expect(conn.isScopeLeaseActive, isFalse);
      });
    });

    test('once the flag is set, a saved contact is still asked normally',
        () {
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        ask(async, conn, (_) {});
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.tableFull]);
        async.flushMicrotasks();
        radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
        async.flushMicrotasks();
        expect(conn.scopeCannotAskNonContacts, isTrue);

        final payload = scopeContactPayload(pubkey: key);
        ScopeRequestOutcome? outcome;
        ask(async, conn, (o) => outcome = o);
        radio.emit(contactFrame(payload));
        async.flushMicrotasks();
        expect(radio.commands.last, CommandCodes.addUpdateContact,
            reason: 'the borrow still happens for a saved contact');
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        radio.emit(sentFrame());
        async.flushMicrotasks();
        expect(radio.commands, contains(CommandCodes.sendAnonReq));
        // The restore (the original route written back) before the lease
        // releases into the answer wait.
        expect(radio.commands.last, CommandCodes.addUpdateContact);
        radio.emit([ResponseCodes.ok]);
        async.flushMicrotasks();
        radio.emit(answerPush());
        async.flushMicrotasks();
        expect(outcome, isA<ScopeAnswered>());
      });
    });
  });

  group('stray replies during the answer wait', () {
    for (final stray in <String, List<List<int>>>{
      'a TX ERR': [
        [ResponseCodes.err, ErrorCodes.notFound]
      ],
      'a discovery ERR': [
        [ResponseCodes.err, ErrorCodes.tableFull]
      ],
      'a trace SENT': [
        sentFrame(tag: [5, 5, 5, 5])
      ],
      'a config OK and ERR': [
        [ResponseCodes.ok],
        [ResponseCodes.err, ErrorCodes.illegalArg]
      ],
      'poll replies (stats ERR, battery)': [
        [ResponseCodes.err, 1],
        [ResponseCodes.batteryVoltage, 0xA0, 0x0F]
      ],
    }.entries) {
      test('${stray.key} never fails the waiter', () {
        onScopeClock(ScopeRadio.new, (async, radio, conn) {
          ScopeRequestOutcome? outcome;
          ask(async, conn, (o) => outcome = o);
          radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
          async.flushMicrotasks();
          radio.emit(sentFrame());
          async.flushMicrotasks();
          expect(conn.isScopeListenActive, isTrue);
          for (final frame in stray.value) {
            radio.emit(frame);
          }
          async.elapse(const Duration(seconds: 1));
          expect(outcome, isNull);
          expect(conn.isScopeListenActive, isTrue);
          radio.emit(answerPush());
          async.flushMicrotasks();
          expect(outcome, isA<ScopeAnswered>());
        });
      });
    }
  });
}
