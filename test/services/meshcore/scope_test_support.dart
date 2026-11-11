import 'dart:async';
import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/meshcore/scope_lease.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

import 'catalog_protocol_transport.dart';
import 'fake_companion_transport.dart';

/// A fake radio whose writes can be made to stall (the transport never
/// returns), for the lease deadline and cancellation cases.
class ScopeRadio extends FakeCompanionTransport {
  /// Commands whose write is recorded and then never returns.
  final Set<int> stallCommands = <int>{};

  /// Set true to record the frame (it reached the radio) and then throw,
  /// the ambiguous-delivery case.
  bool failAfterSend = false;

  @override
  Future<void> write(Uint8List data) async {
    if (failWrites) throw StateError('fake transport link is down');
    writes.add(Uint8List.fromList(data));
    if (failAfterSend) throw StateError('fake transport lost the ack');
    if (data.isNotEmpty && stallCommands.contains(data.first)) {
      await Completer<void>().future;
    }
  }

  /// Command bytes of every write, oldest first.
  List<int> get commands => [for (final w in writes) w.isEmpty ? -1 : w[0]];
}

/// The real connect handshake plus live pollers; scope, TX and config
/// commands are only recorded, so the test answers them by hand.
class PollingScopeRadio extends CatalogProtocolTransport {
  static const Set<int> _manual = {
    CommandCodes.getContactByKey,
    CommandCodes.addUpdateContact,
    CommandCodes.sendAnonReq,
    CommandCodes.sendChannelTxtMsg,
    CommandCodes.sendControlData,
    CommandCodes.setFloodScope,
    CommandCodes.sendLogin,
    CommandCodes.sendBinaryReq,
  };

  @override
  Future<void> write(Uint8List data) async {
    if (data.isNotEmpty && _manual.contains(data.first)) {
      writes.add(Uint8List.fromList(data));
      return;
    }
    await super.write(data);
  }

  int count(int command) => writes.where((w) => w.first == command).length;
}

Uint8List scopeKey(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

/// The 32 raw name bytes: [name] then a NUL then [after] (junk the firmware
/// may leave past the terminator).
Uint8List rawNameBytes(List<int> name, {List<int> after = const []}) {
  final raw = Uint8List(32);
  raw.setRange(0, name.length, name);
  raw.setRange(name.length + 1, name.length + 1 + after.length, after);
  return raw;
}

/// A RESP_CODE_CONTACT payload (147 bytes after the code byte).
Uint8List scopeContactPayload({
  required Uint8List pubkey,
  int type = 2,
  int flags = 0,
  int outPathLen = 0x02,
  List<int> outPath = const [0x4E, 0x7A],
  Uint8List? rawName,
  int lastAdvert = 1700000000,
  int latMicro = 45269740,
  int lonMicro = -75777460,
  int lastMod = 1700000100,
}) {
  final w = BufferWriter();
  w.writeBytes(pubkey);
  w.writeByte(type);
  w.writeByte(flags);
  w.writeByte(outPathLen);
  final path = Uint8List(64)..setRange(0, outPath.length, outPath);
  // Leftover bytes past the live route, as the firmware keeps them.
  path[60] = 0xEE;
  w.writeBytes(path);
  w.writeBytes(rawName ?? rawNameBytes('Hilltop'.codeUnits));
  w.writeUInt32LE(lastAdvert);
  w.writeUInt32LE(latMicro.toUnsigned(32));
  w.writeUInt32LE(lonMicro.toUnsigned(32));
  w.writeUInt32LE(lastMod);
  return w.toBytes();
}

List<int> contactFrame(Uint8List payload) =>
    [ResponseCodes.contact, ...payload];

/// RESP_CODE_SENT: [6][flood][tag:4][est_timeout_ms:u32 LE].
List<int> sentFrame(
        {bool flood = false,
        List<int> tag = const [1, 2, 3, 4],
        int est = 2000}) =>
    [
      ResponseCodes.sent,
      flood ? 1 : 0,
      ...tag,
      est & 0xFF,
      (est >> 8) & 0xFF,
      (est >> 16) & 0xFF,
      (est >> 24) & 0xFF,
    ];

/// PUSH_CODE_BINARY_RESPONSE: [0x8C][reserved][tag:4][body].
List<int> answerPush(
        {List<int> tag = const [1, 2, 3, 4],
        List<int> body = const [9, 9, 9, 9, 0x41]}) =>
    [PushCodes.binaryResponse, 0, ...tag, ...body];

/// Runs [body] on a controlled clock with a connection built inside it.
void onScopeClock<T extends FakeCompanionTransport>(T Function() makeRadio,
    void Function(FakeAsync async, T radio, MeshCoreConnection conn) body) {
  fakeAsync((async) {
    final radio = makeRadio();
    final conn = MeshCoreConnection(transport: radio);
    body(async, radio, conn);
    conn.dispose();
    radio.dispose();
    async.flushMicrotasks();
  });
}

/// Acquires a lease on a quiet radio and returns it (null when refused).
ScopeLease? grant(FakeAsync async, MeshCoreConnection conn,
    {ScopeCancelToken? cancel, Duration wait = const Duration(seconds: 3)}) {
  ScopeLease? lease;
  var done = false;
  conn
      .acquireScopeLease(
          admissionWait: wait, cancel: cancel ?? ScopeCancelToken())
      .then((l) {
    lease = l;
    done = true;
  });
  async.flushMicrotasks();
  if (!done) async.elapse(wait + const Duration(milliseconds: 50));
  expect(done, isTrue, reason: 'admission should have settled');
  return lease;
}

/// Captures every debug log line for the rest of the test.
List<String> captureScopeLog() {
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
