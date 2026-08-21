import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

import 'fake_companion_transport.dart';

/// CMD_SIGN framing contract (mirrors the portal's meshcore.js, which is what
/// today's 1,475 live companion links were made with):
///   [0x21]                -> RESP 19 [0x13][reserved:1][maxSignDataLen:u32 LE]
///   [0x22][<=128 bytes]   -> OK [0x00]   (one per chunk)
///   [0x23]                -> RESP 20 [0x14][sig:64]
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

  /// RESP_SIGN_START carrying [maxLen].
  List<int> signStartResponse(int maxLen) => [
        ResponseCodes.signStart,
        0x00, // reserved
        maxLen & 0xFF,
        (maxLen >> 8) & 0xFF,
        (maxLen >> 16) & 0xFF,
        (maxLen >> 24) & 0xFF,
      ];

  /// RESP_SIGNATURE carrying 64 bytes of [fill].
  List<int> signatureResponse(int fill) =>
      [ResponseCodes.signature, ...List<int>.filled(64, fill)];

  Uint8List nonce32() =>
      Uint8List.fromList(List<int>.generate(32, (i) => i + 1));

  test('signs a 32-byte nonce in one chunk', () async {
    final future = connection.sign(nonce32());

    // 1) CMD_SIGN_START goes out first.
    await transport.settle();
    expect(transport.writes.length, 1);
    expect(transport.commandAt(0), CommandCodes.signStart);
    expect(transport.writes[0].length, 1);

    transport.emit(signStartResponse(128));
    await transport.settle();

    // 2) One CMD_SIGN_DATA frame carrying the raw 32 bytes.
    expect(transport.writes.length, 2);
    expect(transport.commandAt(1), CommandCodes.signData);
    expect(transport.writes[1].sublist(1), nonce32());

    transport.emit([ResponseCodes.ok]);
    await transport.settle();

    // 3) CMD_SIGN_FINISH.
    expect(transport.writes.length, 3);
    expect(transport.commandAt(2), CommandCodes.signFinish);
    expect(transport.writes[2].length, 1);

    transport.emit(signatureResponse(0xAB));

    final signature = await future;
    expect(signature.length, 64);
    expect(signature.every((b) => b == 0xAB), isTrue);
  });

  test('a second sign works after the first one finished', () async {
    Future<Uint8List> runSign() async {
      final future = connection.sign(nonce32());
      await transport.settle();
      transport.emit(signStartResponse(128));
      await transport.settle();
      transport.emit([ResponseCodes.ok]);
      await transport.settle();
      transport.emit(signatureResponse(0x11));
      return future;
    }

    expect((await runSign()).length, 64);
    transport.writes.clear();
    expect((await runSign()).length, 64);
  });

  test('a concurrent sign is refused instead of interleaving', () async {
    final first = connection.sign(nonce32());
    await transport.settle();

    expect(() => connection.sign(nonce32()), throwsA(isA<StateError>()));

    transport.emit(signStartResponse(128));
    await transport.settle();
    transport.emit([ResponseCodes.ok]);
    await transport.settle();
    transport.emit(signatureResponse(0x22));
    expect((await first).length, 64);
  });

  test('signing on a disposed connection throws StateError', () {
    connection.dispose();
    expect(() => connection.sign(nonce32()), throwsA(isA<StateError>()));
  });

  test('the signature never reaches the debug log', () async {
    // Debug logs are uploadable to the bug-report endpoint, so the 64-byte
    // Ed25519 signature must not appear in one — not even via the generic
    // per-frame hexdump that runs before the dispatch switch.
    final logLines = <String>[];
    final originalDebugPrint = debugPrint;
    final originalEnabled = DebugLogger.isEnabled;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) logLines.add(message);
    };
    DebugLogger.setEnabled(true);
    addTearDown(() {
      debugPrint = originalDebugPrint;
      DebugLogger.setEnabled(originalEnabled);
    });

    final future = connection.sign(nonce32());
    await transport.settle();
    transport.emit(signStartResponse(128));
    await transport.settle();
    transport.emit([ResponseCodes.ok]);
    await transport.settle();
    transport.emit(signatureResponse(0xAB));
    expect((await future).length, 64);

    // The harness actually captured something, or the assertions below are
    // vacuously true.
    expect(logLines, isNotEmpty);

    // No line carries the signature bytes in any quantity.
    expect(
      logLines.where((line) => line.contains('ab ab ab')),
      isEmpty,
      reason: 'signature bytes were hex-dumped into the debug log',
    );
    expect(logLines.where((line) => line.contains('ab ab')), isEmpty);

    // The frame is still logged — by length, with the payload redacted.
    expect(
      logLines.where((line) =>
          line.contains('Frame received (65 bytes)') &&
          line.contains('SIGNATURE payload redacted')),
      isNotEmpty,
    );

    // Ordinary frames are untouched: the SIGN_START response and the bare OK
    // still hexdump in full.
    expect(
      logLines.where((line) =>
          line.contains('Frame received (6 bytes): 13 00 80 00 00 00')),
      isNotEmpty,
      reason: 'non-signature frames must keep the existing hexdump',
    );
    expect(
      logLines.where((line) => line.contains('Frame received (1 bytes): 00')),
      isNotEmpty,
    );
  });

  group('write gate', () {
    test('a concurrent command cannot steal the chunk ack', () async {
      final signFuture = connection.sign(nonce32());
      await transport.settle();
      transport.emit(signStartResponse(128));
      await transport.settle();

      // The sign is now waiting for its chunk OK. A zone-transfer timer fires.
      final floodFuture =
          connection.setFloodScope(Uint8List.fromList(List<int>.filled(16, 7)));
      await transport.settle();

      // The gate must have held it back: only SIGN_START and SIGN_DATA are out.
      expect(transport.writes.length, 2);
      expect(transport.commandAt(0), CommandCodes.signStart);
      expect(transport.commandAt(1), CommandCodes.signData);
      expect(
        transport.writes.any((w) => w[0] == CommandCodes.setFloodScope),
        isFalse,
        reason: 'setFloodScope escaped the sign gate',
      );

      // The single OK on the wire belongs to the sign.
      transport.emit([ResponseCodes.ok]);
      await transport.settle();
      expect(transport.commandAt(2), CommandCodes.signFinish);

      transport.emit(signatureResponse(0x33));
      expect((await signFuture).length, 64);

      // Once the sign is done the queued command goes out.
      await floodFuture;
      expect(transport.commandAt(3), CommandCodes.setFloodScope);
    });

    test('queued commands are released in the order they were issued',
        () async {
      final signFuture = connection.sign(nonce32());
      await transport.settle();
      transport.emit(signStartResponse(128));
      await transport.settle();

      final a = connection.setPathHashMode(1);
      final b = connection.getBatteryVoltage();
      await transport.settle();
      expect(transport.writes.length, 2);

      transport.emit([ResponseCodes.ok]);
      await transport.settle();
      transport.emit(signatureResponse(0x44));
      await signFuture;
      await a;
      await b;

      expect(transport.commandAt(3), CommandCodes.setPathHashMode);
      expect(transport.commandAt(4), CommandCodes.getBatteryVoltage);
    });

    test('the gate is released even when the sign fails', () async {
      final signFuture = connection.sign(nonce32());
      await transport.settle();
      transport.emit([ResponseCodes.err, 5]);

      await expectLater(signFuture, throwsA(isA<SignException>()));

      await connection.getBatteryVoltage();
      expect(transport.commandAt(1), CommandCodes.getBatteryVoltage);
    });
  });

  group('failure paths', () {
    test('ERR at SIGN_START reports unsupported and does not hang', () async {
      final future = connection.sign(nonce32());
      await transport.settle();
      transport.emit([ResponseCodes.err, 1]);

      await expectLater(
        future,
        throwsA(
            isA<SignException>().having((e) => e.code, 'code', 'unsupported')),
      );
    });

    test('ERR mid-sign reports err, not unsupported', () async {
      final future = connection.sign(nonce32());
      await transport.settle();
      transport.emit(signStartResponse(128));
      await transport.settle();
      transport.emit([ResponseCodes.err, 3]);

      await expectLater(
        future,
        throwsA(isA<SignException>().having((e) => e.code, 'code', 'err')),
      );
    });

    test('a 300-byte payload is sent as three chunks of 128/128/44', () async {
      final payload =
          Uint8List.fromList(List<int>.generate(300, (i) => i & 0xFF));
      final future = connection.sign(payload);
      await transport.settle();
      transport.emit(signStartResponse(1024));
      await transport.settle();

      expect(transport.writes[1].length, 1 + 128);
      transport.emit([ResponseCodes.ok]);
      await transport.settle();

      expect(transport.writes[2].length, 1 + 128);
      transport.emit([ResponseCodes.ok]);
      await transport.settle();

      expect(transport.writes[3].length, 1 + 44);
      transport.emit([ResponseCodes.ok]);
      await transport.settle();

      expect(transport.commandAt(4), CommandCodes.signFinish);
      transport.emit(signatureResponse(0x55));
      expect((await future).length, 64);
    });

    test('a payload longer than maxSignDataLen is refused before chunking',
        () async {
      final payload = Uint8List.fromList(List<int>.filled(64, 1));
      final future = connection.sign(payload);
      await transport.settle();
      transport.emit(signStartResponse(32));

      await expectLater(
        future,
        throwsA(isA<SignException>()
            .having((e) => e.code, 'code', 'data_too_long')),
      );
      expect(transport.writes.length, 1, reason: 'no chunk should be written');
    });

    test('a short RESP_SIGNATURE fast-fails instead of timing out', () async {
      final future = connection.sign(nonce32());
      await transport.settle();
      transport.emit(signStartResponse(128));
      await transport.settle();
      transport.emit([ResponseCodes.ok]);
      await transport.settle();
      // 20 bytes instead of 64.
      transport.emit([ResponseCodes.signature, ...List<int>.filled(20, 9)]);

      await expectLater(
        future,
        throwsA(isA<SignException>()
            .having((e) => e.code, 'code', 'malformed_response')),
      );
    });

    test('a short RESP_SIGN_START fast-fails', () async {
      final future = connection.sign(nonce32());
      await transport.settle();
      transport.emit([ResponseCodes.signStart, 0x00]); // missing the u32

      await expectLater(
        future,
        throwsA(isA<SignException>()
            .having((e) => e.code, 'code', 'malformed_response')),
      );
    });

    test('a sign that timed out leaves no state behind', () async {
      final timedOut =
          connection.sign(nonce32(), timeout: const Duration(milliseconds: 30));
      await expectLater(timedOut, throwsA(isA<TimeoutException>()));

      // A late response for the abandoned sign must be ignored, not crash.
      transport.emit(signStartResponse(128));
      await transport.settle();

      transport.writes.clear();
      final second = connection.sign(nonce32());
      await transport.settle();
      transport.emit(signStartResponse(128));
      await transport.settle();
      transport.emit([ResponseCodes.ok]);
      await transport.settle();
      transport.emit(signatureResponse(0x66));
      expect((await second).length, 64);
    });

    test('an interleaved battery push does not disturb the sign', () async {
      final future = connection.sign(nonce32());
      await transport.settle();
      transport.emit(signStartResponse(128));
      await transport.settle();

      // Battery voltage response (0x0C) arriving mid-sign.
      transport.emit([ResponseCodes.batteryVoltage, 0x10, 0x0F, 0x00, 0x00]);
      await transport.settle();
      expect(transport.writes.length, 2, reason: 'sign must not advance');

      transport.emit([ResponseCodes.ok]);
      await transport.settle();
      transport.emit(signatureResponse(0x77));
      expect((await future).length, 64);
    });

    test('disconnect aborts an in-flight sign', () async {
      final future = connection.sign(nonce32());
      await transport.settle();

      // Attach the expectation BEFORE triggering the abort. The teardown paths
      // reject the sign synchronously, and a future that errors while nothing
      // is listening yet is reported to the zone as an unhandled error — which
      // fails the test even though expectLater would match it a microtask
      // later. The assertion itself is unchanged.
      final aborted = expectLater(
        future,
        throwsA(isA<SignException>().having((e) => e.code, 'code', 'aborted')),
      );

      await connection.disconnect();
      await aborted;
    });

    test('deleteWardrivingChannelEarly is not blocked by a pending sign',
        () async {
      final future = connection.sign(nonce32());
      await transport.settle();

      final aborted = expectLater(
        future,
        throwsA(isA<SignException>().having((e) => e.code, 'code', 'aborted')),
      );

      // Must return promptly, not sit behind the 5s sign timeout.
      await connection.deleteWardrivingChannelEarly();
      await aborted;
    });

    test('abortPendingSign releases the gate for teardown-time writes',
        () async {
      final future = connection.sign(nonce32());
      await transport.settle();
      expect(transport.commandAt(0), CommandCodes.signStart);

      final aborted = expectLater(
        future,
        throwsA(isA<SignException>().having((e) => e.code, 'code', 'aborted')),
      );

      // What the provider will call FIRST in its disconnect sequence.
      connection.abortPendingSign();
      await aborted;

      // A gated write now goes out immediately instead of waiting out the
      // sign's 5s timeout — this is the whole point of the public hook.
      await connection.getBatteryVoltage();
      expect(transport.commandAt(1), CommandCodes.getBatteryVoltage);
    });

    test('abortPendingSign is safe when no sign is running', () async {
      connection.abortPendingSign();
      await connection.getBatteryVoltage();
      expect(transport.commandAt(0), CommandCodes.getBatteryVoltage);
    });
  });
}
