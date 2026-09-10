import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_models.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_session.dart';

import '../meshcore/fake_companion_transport.dart';

/// The repeater under management: key 0x5A * 32, so its 6-byte login prefix
/// is 0x5A * 6 and the harness can reuse [repeaterKey] for the reply.
final Uint8List repeaterKey = Uint8List.fromList(List<int>.filled(32, 0x5A));
final Uint8List otherKey = Uint8List.fromList(List<int>.filled(32, 0x11));

/// A RESP_CODE_CONTACT payload (147 bytes after the code byte), the same
/// layout repeater_admin_frames_test.dart round-trips.
List<int> contactPayload(Uint8List pubkey,
    {int outPathLen = 0xFF, List<int> outPath = const [], String name = 'Hilltop'}) {
  final w = BufferWriter();
  w.writeBytes(pubkey);
  w.writeByte(2); // ADV_TYPE_REPEATER
  w.writeByte(0);
  w.writeByte(outPathLen);
  final path = Uint8List(64)..setRange(0, outPath.length, outPath);
  w.writeBytes(path);
  w.writeCString(name, 32);
  w.writeUInt32LE(1700000000);
  w.writeUInt32LE(45269740);
  w.writeUInt32LE((-75777460).toUnsigned(32));
  w.writeUInt32LE(1700000100);
  return w.toBytes();
}

/// RESP_CODE_SENT [flood:1][tag:4][est_timeout_ms:u32].
List<int> sent(List<int> tag, {int est = 0}) => [
      ResponseCodes.sent, 1, ...tag,
      est & 0xFF, (est >> 8) & 0xFF, (est >> 16) & 0xFF, (est >> 24) & 0xFF,
    ];

/// LOGIN_SUCCESS (14 bytes on the wire): [0x85][is_admin][prefix:6][tag:4][acl_perms][fw_level].
List<int> loginSuccess({required bool admin, int aclPerms = 3, int fwLevel = 2}) => [
      PushCodes.loginSuccess, admin ? 1 : 0,
      ...repeaterKey.sublist(0, 6),
      1, 2, 3, 4,
      aclPerms, fwLevel,
    ];

void main() {
  late FakeCompanionTransport transport;
  late MeshCoreConnection connection;
  late RepeaterAdminSession session;
  final target = RepeaterTarget(
      hexId: bytesToHex(repeaterKey), name: 'Hilltop', lat: 45.26974, lon: -75.77746);

  setUp(() {
    transport = FakeCompanionTransport();
    connection = MeshCoreConnection(transport: transport);
    session = RepeaterAdminSession(
      connection: connection,
      target: target,
      hopBytes: 1,
      hopNameFor: (h) => h == '4E' ? 'Hill' : null,
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

  /// The command bytes written so far, oldest first.
  List<int> commands() => transport.writes.map((w) => w[0]).toList();

  /// Answer the pending CMD_GET_CONTACTS with [payloads] (each a 147-byte
  /// contact payload), then let the session continue.
  Future<void> answerContacts(List<List<int>> payloads) async {
    await transport.settle();
    expect(transport.writes.last[0], CommandCodes.getContacts,
        reason: 'the session should be reading the contact list');
    transport.emit([ResponseCodes.contactsStart, payloads.length, 0, 0, 0]);
    for (final p in payloads) {
      transport.emit([ResponseCodes.contact, ...p]);
    }
    transport.emit([ResponseCodes.endOfContacts, 0, 0, 0, 0]);
    await transport.settle();
  }

  /// Answer the pending CMD_SEND_LOGIN: SENT, then the [push] (or nothing,
  /// which is what a wrong password gets).
  Future<void> answerLogin(List<int>? push) async {
    await transport.settle();
    expect(transport.writes.last[0], CommandCodes.sendLogin);
    transport.emit(sent([0x5A, 0x5A, 0x5A, 0x5A]));
    await transport.settle();
    if (push != null) transport.emit(push);
    await transport.settle();
  }

  /// Answer the pending CMD_SEND_BINARY_REQ with SENT (tag 0xAA*4) and, when
  /// [data] is given, a BINARY_RESPONSE carrying it. Null is silence.
  Future<void> answerBinary(List<int>? data) async {
    await transport.settle();
    expect(transport.writes.last[0], CommandCodes.sendBinaryReq);
    transport.emit(sent([0xAA, 0xAA, 0xAA, 0xAA]));
    await transport.settle();
    if (data != null) {
      transport.emit([PushCodes.binaryResponse, 0, 0xAA, 0xAA, 0xAA, 0xAA, ...data]);
    }
    await transport.settle();
  }

  /// Contact present, admin login answered: the session ends in `admin`.
  Future<void> loginAsAdmin() async {
    final future = session.login('admin-pw');
    await answerContacts([contactPayload(repeaterKey)]);
    await answerLogin(loginSuccess(admin: true));
    expect(await future, isTrue);
    expect(session.state, RepeaterAdminState.admin);
  }

  group('login', () {
    test('contact present: no add, admin reply proves the flag', () async {
      final future = session.login('admin-pw');
      await answerContacts([contactPayload(repeaterKey)]);
      expect(session.state, RepeaterAdminState.loggingIn);
      await answerLogin(loginSuccess(admin: true));
      expect(await future, isTrue);
      expect(commands(), [CommandCodes.getContacts, CommandCodes.sendLogin]);
      expect(session.isAdmin, isTrue);
      expect(session.isLoggedIn, isTrue);
      expect(session.lastError, isNull);
      expect(session.busy, isFalse);
      expect(session.describeRoute(), 'Flood (no route learned yet)');
    });

    test('contact absent: added as a flood repeater, then login', () async {
      final future = session.login('admin-pw');
      await answerContacts([contactPayload(otherKey)]);
      expect(session.state, RepeaterAdminState.ensuringContact);
      final add = transport.writes.last;
      expect(add[0], CommandCodes.addUpdateContact);
      expect(add.length, 148);
      expect(add.sublist(1, 33), repeaterKey);
      expect(add[33], AdvTypes.repeater);
      expect(add[35], ProtocolConstants.outPathUnknown);
      transport.emit([ResponseCodes.ok]);
      await answerLogin(loginSuccess(admin: true));
      expect(await future, isTrue);
      expect(commands(), [
        CommandCodes.getContacts, CommandCodes.addUpdateContact, CommandCodes.sendLogin,
      ]);
    });

    test('contact table full stops before the login', () async {
      final future = session.login('admin-pw');
      await answerContacts([]);
      transport.emit([ResponseCodes.err, ErrorCodes.tableFull]);
      expect(await future, isFalse);
      expect(session.state, RepeaterAdminState.failed);
      expect(session.lastError, "Your radio's contact list is full.");
      expect(commands(), [CommandCodes.getContacts, CommandCodes.addUpdateContact]);
    });

    test('a guest reply is guest, not an error', () async {
      final future = session.login('guest-pw');
      await answerContacts([contactPayload(repeaterKey)]);
      await answerLogin(loginSuccess(admin: false, aclPerms: 1));
      expect(await future, isFalse);
      expect(session.state, RepeaterAdminState.guest);
      expect(session.isAdmin, isFalse);
      expect(session.isLoggedIn, isTrue);
      expect(session.lastError, isNull);
    });

    test('a wrong password is silence: the timeout names both causes', () async {
      final future = session.login('wrong');
      await answerContacts([contactPayload(repeaterKey)]);
      await answerLogin(null);
      expect(await future, isFalse);
      expect(session.state, RepeaterAdminState.failed);
      expect(session.lastError,
          'No reply from the repeater. Check the password and try again.');
      expect(session.busy, isFalse);
    });

    test('LOGIN_FAIL is a rejection', () async {
      final future = session.login('x');
      await answerContacts([contactPayload(repeaterKey)]);
      await answerLogin([PushCodes.loginFail, 0, ...repeaterKey.sublist(0, 6)]);
      expect(await future, isFalse);
      expect(session.lastError, 'The repeater rejected the login.');
    });

    test('firmware level 0 is a repeater older than v1.9.0', () async {
      final future = session.login('admin-pw');
      await answerContacts([contactPayload(repeaterKey)]);
      await answerLogin(loginSuccess(admin: true, fwLevel: 0));
      expect(await future, isFalse);
      expect(session.state, RepeaterAdminState.failed);
      expect(session.lastError, kRepeaterFirmwareFloorSentence);
      expect(commands().length, 2, reason: 'nothing further is sent to it');
    });

    test('a short LOGIN_SUCCESS is the companion floor sentence', () async {
      final future = session.login('admin-pw');
      await answerContacts([contactPayload(repeaterKey)]);
      await answerLogin([PushCodes.loginSuccess, 1, ...repeaterKey.sublist(0, 6)]);
      expect(await future, isFalse);
      expect(session.state, RepeaterAdminState.failed);
      expect(session.lastError, kCompanionFirmwareFloorSentence);
    });

    test('an existing route renders as named hops', () async {
      final future = session.login('admin-pw');
      await answerContacts([
        contactPayload(repeaterKey, outPathLen: 2, outPath: [0x4E, 0x7A]),
      ]);
      await answerLogin(loginSuccess(admin: true));
      await future;
      expect(session.route?.hops, ['4E', '7A']);
      expect(session.describeRoute(), 'Hill > 7A');
    });

    test('a command while busy is refused without a write', () async {
      final future = session.login('admin-pw');
      await transport.settle();
      expect(session.busy, isTrue);
      expect(await session.resetRoute(), isFalse);
      expect(commands(), [CommandCodes.getContacts]);
      await answerContacts([contactPayload(repeaterKey)]);
      await answerLogin(loginSuccess(admin: true));
      expect(await future, isTrue);
    });
  });

  group('proveAdmin', () {
    test('an ACL reply is the proof', () async {
      await loginAsAdmin();
      final future = session.proveAdmin();
      await answerBinary([
        9, 0, 0, 0, // sender ts
        1, 2, 3, 4, 5, 6, 3, // an admin entry
        7, 7, 7, 7, 7, 7, 1, // a guest entry
      ]);
      expect(await future, isTrue);
      final req = transport.writes.last;
      expect(req, [CommandCodes.sendBinaryReq, ...repeaterKey, 0x05, 0, 0]);
      final proof = session.proof!;
      expect(proof.isProven, isTrue);
      expect(proof.aclEntries, 2);
      expect(proof.toWire(), {'login': 'admin', 'acl': true, 'perms': 3, 'fw_level': 2});
      expect(session.lastError, isNull);
      expect(session.state, RepeaterAdminState.admin);
    });

    test('silence refuses the claim and keeps the admin state', () async {
      await loginAsAdmin();
      final future = session.proveAdmin();
      await answerBinary(null);
      expect(await future, isFalse);
      expect(session.lastError, kAclUnansweredSentence);
      expect(session.proof?.isProven, isFalse);
      expect(session.state, RepeaterAdminState.admin);
      expect(session.busy, isFalse);
    });

    test('before an admin login it is refused without a write', () async {
      expect(await session.proveAdmin(), isFalse);
      expect(session.lastError, 'Log in with the admin password first.');
      expect(transport.writes, isEmpty);
    });
  });

  group('route', () {
    test('resetRoute floods the contact', () async {
      await loginAsAdmin();
      final future = session.resetRoute();
      await transport.settle();
      expect(transport.writes.last, [CommandCodes.resetPath, ...repeaterKey]);
      transport.emit([ResponseCodes.ok]);
      expect(await future, isTrue);
      expect(session.route?.flood, isTrue);
    });

    test('PATH_UPDATED re-reads the contact', () async {
      await loginAsAdmin();
      final writes = transport.writes.length;
      transport.emit([PushCodes.pathUpdated, ...repeaterKey]);
      await answerContacts([
        contactPayload(repeaterKey, outPathLen: 1, outPath: [0x7A]),
      ]);
      expect(transport.writes.length, writes + 1);
      expect(session.describeRoute(), '7A');
    });

    test('PATH_UPDATED for another contact is ignored', () async {
      await loginAsAdmin();
      final writes = transport.writes.length;
      transport.emit([PushCodes.pathUpdated, ...otherKey]);
      await transport.settle();
      expect(transport.writes.length, writes);
    });
  });

  group('neighbours', () {
    List<int> page({required int total, required int returned, int fill = 1}) => [
          0, 0, 0, 0,
          total & 0xFF, total >> 8,
          returned & 0xFF, returned >> 8,
          for (var i = 0; i < returned; i++) ...[
            ...List<int>.filled(8, fill + i), 10, 0, 0, 0, 0xFC, // -1.0 dB
          ],
        ];

    int offsetOfLastRequest() {
      final req = transport.writes.last.sublist(33);
      return req[3] | (req[4] << 8);
    }

    test('fetch is one page, load more is the next', () async {
      await loginAsAdmin();
      final first = session.fetchNeighbours();
      await answerBinary(page(total: 25, returned: 10));
      expect(await first, isTrue);
      expect(offsetOfLastRequest(), 0);
      expect(session.neighbours.length, 10);
      expect(session.neighboursTotal, 25);
      expect(session.neighbourPagesFetched, 1);
      expect(session.hasMoreNeighbours, isTrue);
      expect(session.neighbours.first.snrDb, -1.0);
      expect(session.neighboursFetchedAt, isNotNull);

      final second = session.loadMoreNeighbours();
      await answerBinary(page(total: 25, returned: 10, fill: 20));
      expect(await second, isTrue);
      expect(offsetOfLastRequest(), 10);
      expect(session.neighbours.length, 20);
      expect(session.hasMoreNeighbours, isTrue);

      final third = session.loadMoreNeighbours();
      await answerBinary(page(total: 25, returned: 5, fill: 40));
      expect(await third, isTrue);
      expect(offsetOfLastRequest(), 20);
      expect(session.neighbours.length, 25);
      expect(session.neighbourPagesFetched, 3);
      expect(session.hasMoreNeighbours, isFalse);
    });

    test('a zero page ends the list', () async {
      await loginAsAdmin();
      final first = session.fetchNeighbours();
      await answerBinary(page(total: 30, returned: 10));
      await first;
      final more = session.loadMoreNeighbours();
      await answerBinary(page(total: 30, returned: 0));
      expect(await more, isTrue);
      expect(session.neighbours.length, 10);
      expect(session.hasMoreNeighbours, isFalse);
    });

    test('load more before a fetch, or with nothing more, is refused', () async {
      await loginAsAdmin();
      final writes = transport.writes.length;
      expect(await session.loadMoreNeighbours(), isFalse);
      expect(transport.writes.length, writes);
      final first = session.fetchNeighbours();
      await answerBinary(page(total: 3, returned: 3));
      await first;
      expect(session.hasMoreNeighbours, isFalse);
      expect(await session.loadMoreNeighbours(), isFalse);
      expect(transport.writes.length, writes + 1);
    });

    test('fetch again starts over from offset 0', () async {
      await loginAsAdmin();
      final first = session.fetchNeighbours();
      await answerBinary(page(total: 25, returned: 10));
      await first;
      final more = session.loadMoreNeighbours();
      await answerBinary(page(total: 25, returned: 10, fill: 20));
      await more;
      final again = session.fetchNeighbours();
      await answerBinary(page(total: 25, returned: 10));
      await again;
      expect(offsetOfLastRequest(), 0);
      expect(session.neighbours.length, 10);
      expect(session.neighbourPagesFetched, 1);
    });

    test('the 30-page brake', () async {
      await loginAsAdmin();
      final first = session.fetchNeighbours();
      await answerBinary(page(total: 1000, returned: 10));
      await first;
      for (var i = 1; i < kNeighbourMaxPages; i++) {
        final more = session.loadMoreNeighbours();
        await answerBinary(page(total: 1000, returned: 10));
        expect(await more, isTrue);
      }
      expect(session.neighbourPagesFetched, kNeighbourMaxPages);
      expect(session.neighbours.length, 300);
      expect(session.hasMoreNeighbours, isFalse);
      final writes = transport.writes.length;
      expect(await session.loadMoreNeighbours(), isFalse);
      expect(transport.writes.length, writes);
    });

    test('silence is old firmware', () async {
      await loginAsAdmin();
      final future = session.fetchNeighbours();
      await answerBinary(null);
      expect(await future, isFalse);
      expect(session.lastError, "This repeater's firmware cannot report neighbours.");
      expect(session.hasMoreNeighbours, isFalse);
    });

    test('a failed load more keeps the pages already fetched', () async {
      await loginAsAdmin();
      final first = session.fetchNeighbours();
      await answerBinary(page(total: 25, returned: 10));
      await first;
      final more = session.loadMoreNeighbours();
      await answerBinary(null);
      expect(await more, isFalse);
      expect(session.neighbours.length, 10);
      expect(session.hasMoreNeighbours, isTrue, reason: 'the user may retry');
    });

    test('names resolve through the lookup', () async {
      session.close();
      session = RepeaterAdminSession(
        connection: connection,
        target: target,
        hopBytes: 1,
        neighbourNameFor: (p) => p.startsWith('01') ? 'Valley' : null,
        timeoutMargin: const Duration(milliseconds: 40),
        minTimeout: const Duration(milliseconds: 40),
        maxTimeout: const Duration(milliseconds: 200),
      );
      await loginAsAdmin();
      final future = session.fetchNeighbours();
      await answerBinary(page(total: 1, returned: 1));
      await future;
      expect(session.neighbours.single.name, 'Valley');
    });
  });

  group('abort', () {
    test('dispose mid-login completes the login and clears busy', () async {
      final future = session.login('x');
      await answerContacts([contactPayload(repeaterKey)]);
      await transport.settle();
      transport.emit(sent([0x5A, 0x5A, 0x5A, 0x5A], est: 60000));
      await transport.settle();
      connection.dispose();
      expect(await future, isFalse);
      expect(session.busy, isFalse);
      expect(session.state, RepeaterAdminState.failed);
      expect(session.lastError, 'The radio disconnected.');
    });

    test('close after login is idempotent and stops listening', () async {
      await loginAsAdmin();
      session.close();
      session.close();
      expect(session.closed, isTrue);
      final writes = transport.writes.length;
      transport.emit([PushCodes.pathUpdated, ...repeaterKey]);
      await transport.settle();
      expect(transport.writes.length, writes);
    });

    test('timeouts are clamped', () {
      expect(session.timeoutFor(0), const Duration(milliseconds: 40));
      expect(session.timeoutFor(100), const Duration(milliseconds: 140));
      expect(session.timeoutFor(10000), const Duration(milliseconds: 200));
    });
  });
}
