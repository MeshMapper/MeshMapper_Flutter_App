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
}
