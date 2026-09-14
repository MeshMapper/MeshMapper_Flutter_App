import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_models.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_module.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_session.dart';

import '../meshcore/fake_companion_transport.dart';

final Uint8List _repeaterKey =
    Uint8List.fromList(List<int>.filled(32, 0x5A));

List<int> _contactPayload() {
  final writer = BufferWriter()
    ..writeBytes(_repeaterKey)
    ..writeByte(AdvTypes.repeater)
    ..writeByte(0)
    ..writeByte(ProtocolConstants.outPathUnknown)
    ..writeBytes(Uint8List(64))
    ..writeCString('Hilltop', 32)
    ..writeUInt32LE(1700000000)
    ..writeUInt32LE(45269740)
    ..writeUInt32LE((-75777460).toUnsigned(32))
    ..writeUInt32LE(1700000100);
  return writer.toBytes();
}

List<int> _sent(List<int> tag) => [
      ResponseCodes.sent,
      1,
      ...tag,
      0,
      0,
      0,
      0,
    ];

List<int> _loginSuccess() => [
      PushCodes.loginSuccess,
      1,
      ..._repeaterKey.sublist(0, 6),
      1,
      2,
      3,
      4,
      3,
      2,
    ];

void main() {
  late FakeCompanionTransport transport;
  late MeshCoreConnection connection;
  late RepeaterAdminSession session;

  setUp(() {
    transport = FakeCompanionTransport();
    connection = MeshCoreConnection(transport: transport);
    session = RepeaterAdminSession(
      connection: connection,
      target: RepeaterTarget(
        hexId: bytesToHex(_repeaterKey),
        name: 'Hilltop',
        lat: 45.26974,
        lon: -75.77746,
      ),
      hopBytes: 1,
      timeoutMargin: const Duration(milliseconds: 40),
      minTimeout: const Duration(milliseconds: 40),
      maxTimeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() {
    session.close();
    connection.dispose();
    transport.dispose();
  });

  Future<void> loginAsAdmin() async {
    final login = session.login('admin-password');
    await transport.settle();
    transport.emit([ResponseCodes.contactsStart, 1, 0, 0, 0]);
    transport.emit([ResponseCodes.contact, ..._contactPayload()]);
    transport.emit([ResponseCodes.endOfContacts, 0, 0, 0, 0]);
    await transport.settle();
    expect(transport.writes.last[0], CommandCodes.sendLogin);
    transport.emit(_sent([0x5A, 0x5A, 0x5A, 0x5A]));
    await transport.settle();
    transport.emit(_loginSuccess());
    expect(await login, isTrue);
  }

  test('NeighboursModule shapes and caps the table', () {
    final entries = List<RepeaterNeighbour>.generate(
        305,
        (i) => RepeaterNeighbour(
            prefixHex: i.toRadixString(16).padLeft(16, '0').toUpperCase(),
            heardSecsAgo: i,
            snrDb: -1.5));
    final payload = NeighboursModule.payloadFor(
        entries: entries,
        total: 400,
        fetchedAt: DateTime.fromMillisecondsSinceEpoch(1700000000000));
    expect(payload['fetched_at'], 1700000000);
    expect(payload['total'], 400);
    expect((payload['entries'] as List).length, kNeighbourUploadCap);
    expect((payload['entries'] as List).first,
        {'prefix': '0' * 16, 'snr': -1.5, 'heard_secs_ago': 0});
  });

  test('only ClaimModule needs admin access', () {
    expect(ClaimModule().needsAdmin, isTrue);
    expect(NeighboursModule().needsAdmin, isFalse);
    expect(ClaimModule().name, 'claim');
    expect(NeighboursModule().name, 'neighbours');
  });

  test('ClaimModule.run obtains and returns the real admin proof', () async {
    await loginAsAdmin();

    final future = ClaimModule().run(session);
    await transport.settle();
    expect(transport.writes.last,
        [CommandCodes.sendBinaryReq, ..._repeaterKey, 0x05, 0, 0]);
    transport.emit(_sent([0xAA, 0xAA, 0xAA, 0xAA]));
    await transport.settle();
    transport.emit([
      PushCodes.binaryResponse,
      0,
      0xAA,
      0xAA,
      0xAA,
      0xAA,
      1,
      2,
      3,
      4,
      5,
      6,
      3,
    ]);

    expect(await future,
        {'login': 'admin', 'acl': true, 'perms': 3, 'fw_level': 2});
  });

  test('NeighboursModule.run returns the page fetched by the real session',
      () async {
    await loginAsAdmin();
    final beforeFetch = DateTime.now().millisecondsSinceEpoch ~/ 1000;

    final fetch = session.fetchNeighbours();
    await transport.settle();
    expect(transport.writes.last[0], CommandCodes.sendBinaryReq);
    transport.emit(_sent([0xBB, 0xBB, 0xBB, 0xBB]));
    await transport.settle();
    transport.emit([
      PushCodes.binaryResponse,
      0,
      0xBB,
      0xBB,
      0xBB,
      0xBB,
      1,
      0,
      1,
      0,
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
      10,
      0,
      0,
      0,
      0xFC,
    ]);
    expect(await fetch, isTrue);

    final payload = await NeighboursModule().run(session);
    final afterFetch = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    expect(payload['fetched_at'], inInclusiveRange(beforeFetch, afterFetch));
    expect(payload['total'], 1);
    expect(payload['entries'], [
      {
        'prefix': '0102030405060708',
        'snr': -1.0,
        'heard_secs_ago': 10,
      }
    ]);
  });
}
