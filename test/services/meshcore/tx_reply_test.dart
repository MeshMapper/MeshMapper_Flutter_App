import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

import 'catalog_protocol_transport.dart';
import 'fake_companion_transport.dart';

/// Runs the real connect handshake, then answers a channel message the way
/// the firmware does: a bare OK, here 5 ms after the write.
class _OkAfterTxTransport extends CatalogProtocolTransport {
  @override
  Future<void> write(Uint8List data) async {
    if (data.isNotEmpty && data.first == CommandCodes.sendChannelTxtMsg) {
      writes.add(Uint8List.fromList(data));
      Timer(const Duration(milliseconds: 5), () => emit([ResponseCodes.ok]));
      return;
    }
    await super.write(data);
  }
}

/// The companion firmware answers CMD_SEND_CHANNEL_TXT_MSG and
/// CMD_SEND_CONTROL_DATA (discovery) with a bare OK or ERR, never with
/// RESP_CODE_SENT (examples/companion_radio/MyMesh.cpp). A TX send therefore
/// has to wait for its own OK, and both sends have to claim their reply so it
/// cannot complete some other command's OK waiter.
void main() {
  late FakeCompanionTransport transport;
  late MeshCoreConnection connection;

  setUp(() {
    transport = FakeCompanionTransport();
    connection = MeshCoreConnection(transport: transport);
  });

  tearDown(() {
    connection.dispose();
    transport.dispose();
  });

  Uint8List key(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

  ContactRecord contact() => ContactRecord.newRepeater(
      publicKey: key(9), name: 'R', lat: 1, lon: 2, nowSecs: 5);

  Future<void> sendTx() => connection.sendChannelTextMessage(0, 1, 0, 'MM:x');

  /// Resolves true once [future] completes, false while it is still pending.
  Future<bool> isDone(Future<void> future) async {
    var done = false;
    unawaited(future.then((_) => done = true, onError: (_) => done = true));
    await transport.settle();
    await transport.settle();
    return done;
  }

  List<String> captureLog() {
    final lines = <String>[];
    final originalDebugPrint = debugPrint;
    final originalEnabled = DebugLogger.isEnabled;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    DebugLogger.setEnabled(true);
    addTearDown(() {
      debugPrint = originalDebugPrint;
      DebugLogger.setEnabled(originalEnabled);
    });
    return lines;
  }

  /// Runs [body] on a controlled clock with a connection built inside it, so
  /// every timer (the reply budget included) is fake and nothing is timed on
  /// the wall clock.
  void onFakeClock(
      FakeCompanionTransport Function() makeTransport,
      void Function(FakeAsync async, FakeCompanionTransport transport,
              MeshCoreConnection connection)
          body) {
    fakeAsync((async) {
      final fakeTransport = makeTransport();
      final fakeConnection = MeshCoreConnection(transport: fakeTransport);
      body(async, fakeTransport, fakeConnection);
      fakeConnection.dispose();
      fakeTransport.dispose();
      async.flushMicrotasks();
    });
  }

  test('sendPing on a connected radio returns 5 ms after its OK is sent',
      () {
    final lines = captureLog();
    onFakeClock(_OkAfterTxTransport.new, (async, radio, conn) {
      var connected = false;
      conn.connect((_) async => null).then((_) => connected = true);
      // connect() lets the link settle for 500 ms before its first query.
      async.elapse(const Duration(seconds: 1));
      expect(connected, isTrue);
      expect(conn.wardrivingChannel?.name, '#wardriving');

      var done = false;
      conn.sendPing('MM:YVNPAr5OIw').then((_) => done = true);
      async.flushMicrotasks();
      expect(radio.writes.last.first, CommandCodes.sendChannelTxtMsg);

      // The radio replies OK 5 ms after the write.
      async.elapse(const Duration(milliseconds: 4));
      expect(done, isFalse);
      async.elapse(const Duration(milliseconds: 6));
      expect(done, isTrue, reason: 'sendPing must finish within 10 ms');
    });
    expect(lines.any((l) => l.contains('[CONN] OK claimed by TX send')),
        isTrue);
  });

  test('a TX returns as soon as its own OK arrives, not after 3 s', () {
    onFakeClock(FakeCompanionTransport.new, (async, radio, conn) {
      var done = false;
      conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) => done = true);
      async.flushMicrotasks();
      expect(radio.commandAt(0), CommandCodes.sendChannelTxtMsg);
      Timer(const Duration(milliseconds: 5),
          () => radio.emit([ResponseCodes.ok]));
      async.elapse(const Duration(milliseconds: 10));
      expect(done, isTrue);
    });
  });

  test('a TX ERR returns at once and is logged as a warning', () {
    final lines = captureLog();
    onFakeClock(FakeCompanionTransport.new, (async, radio, conn) {
      var done = false;
      conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) => done = true);
      async.flushMicrotasks();
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      async.flushMicrotasks();
      expect(done, isTrue);
    });
    expect(
        lines.any((l) =>
            l.contains('[CONN]') &&
            l.contains('TX send rejected by radio') &&
            l.contains('error code ${ErrorCodes.notFound}')),
        isTrue);
  });

  test('a TX with no reply returns after 3 s and releases its claim', () {
    onFakeClock(FakeCompanionTransport.new, (async, radio, conn) {
      var done = false;
      conn.sendChannelTextMessage(0, 1, 0, 'MM:x').then((_) => done = true);
      async.elapse(const Duration(milliseconds: 2999));
      expect(done, isFalse);
      async.elapse(const Duration(milliseconds: 1));
      expect(done, isTrue);

      // The expired claim must not swallow the next command's OK.
      var added = false;
      conn.addContact(contact()).then((_) => added = true);
      async.flushMicrotasks();
      radio.emit([ResponseCodes.ok]);
      async.flushMicrotasks();
      expect(added, isTrue);
    });
  });

  test('a TX OK goes to the TX and the admin OK to the admin', () async {
    final tx = sendTx();
    await transport.settle();
    final add = connection.addContact(contact());
    await transport.settle();
    expect(transport.commandAt(1), CommandCodes.addUpdateContact);

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(tx), isTrue);
    expect(await isDone(add), isFalse);

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  });

  test('a discovery OK never completes an admin waiter', () async {
    await connection.sendDiscoveryRequest();
    final add = connection.addContact(contact());
    await transport.settle();

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isFalse);

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  });

  test('a discovery ERR never fails an admin waiter', () async {
    await connection.sendDiscoveryRequest();
    final add = connection.addContact(contact());
    await transport.settle();

    transport.emit([ResponseCodes.err, ErrorCodes.tableFull]);
    expect(await isDone(add), isFalse);

    transport.emit([ResponseCodes.ok]);
    await add;
  });

  test('a discovery OK never completes a sign chunk', () async {
    await connection.sendDiscoveryRequest();
    final sign = connection
        .sign(Uint8List.fromList(List<int>.generate(32, (i) => i + 1)));
    await transport.settle();

    // The radio answers in command order: the discovery OK first.
    transport.emit([ResponseCodes.ok]);
    transport.emit([ResponseCodes.signStart, 0, 128, 0, 0, 0]);
    await transport.settle();
    expect(transport.commandAt(2), CommandCodes.signData);

    // The chunk is still waiting for its own OK.
    await transport.settle();
    expect(transport.writes.length, 3);

    transport.emit([ResponseCodes.ok]);
    await transport.settle();
    expect(transport.commandAt(3), CommandCodes.signFinish);
    transport.emit([ResponseCodes.signature, ...List<int>.filled(64, 0xAB)]);
    expect((await sign).length, 64);
  });

  test('replies are claimed oldest first across TX and discovery', () async {
    final lines = captureLog();
    await connection.sendDiscoveryRequest();
    final tx = sendTx();
    await transport.settle();

    transport.emit([ResponseCodes.ok]);
    expect(await isDone(tx), isFalse);

    transport.emit([ResponseCodes.err, ErrorCodes.notFound]);
    expect(await isDone(tx), isTrue);
    expect(lines.any((l) => l.contains('TX send rejected by radio')), isTrue);
  });

  test('an unanswered discovery claim expires and stops claiming', () async {
    connection.ownReplyTimeout = const Duration(milliseconds: 20);
    await connection.sendDiscoveryRequest();
    await Future<void>.delayed(const Duration(milliseconds: 60));

    final add = connection.addContact(contact());
    await transport.settle();
    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  });

  test('a failed TX write leaves no claim behind', () async {
    transport.failWrites = true;
    await expectLater(sendTx(), throwsA(isA<StateError>()));
    transport.failWrites = false;

    final add = connection.addContact(contact());
    await transport.settle();
    transport.emit([ResponseCodes.ok]);
    expect(await isDone(add), isTrue);
  });

  test('dispose releases a TX still waiting for its reply', () async {
    final tx = sendTx();
    await transport.settle();
    connection.dispose();
    expect(await isDone(tx), isTrue);
  });
}
