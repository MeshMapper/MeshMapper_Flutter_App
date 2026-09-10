import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

import 'fake_companion_transport.dart';

/// Byte vectors for the repeater-admin frames, taken from
/// examples/companion_radio/MyMesh.cpp (writeContactRespFrame,
/// updateContactFromFrame, CMD_SEND_LOGIN, CMD_SEND_BINARY_REQ,
/// onContactResponse, onContactPathUpdated).
Uint8List key(int fill) => Uint8List.fromList(List<int>.filled(32, fill));

/// A RESP_CODE_CONTACT payload (147 bytes after the code byte).
List<int> contactPayload({
  required Uint8List pubkey,
  int type = 2,
  int flags = 0,
  int outPathLen = 0xFF,
  List<int> outPath = const [],
  String name = 'Hilltop',
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
  w.writeBytes(path);
  w.writeCString(name, 32);
  w.writeUInt32LE(lastAdvert);
  w.writeUInt32LE(latMicro.toUnsigned(32));
  w.writeUInt32LE(lonMicro.toUnsigned(32));
  w.writeUInt32LE(lastMod);
  return w.toBytes();
}

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

  group('ContactRecord', () {
    test('round-trips the 147-byte payload', () {
      final payload = contactPayload(
          pubkey: key(0xAB), outPathLen: 2, outPath: [0x4E, 0x7A]);
      expect(payload.length, ContactRecord.payloadLength);
      final rec = ContactRecord.parse(BufferReader(payload));
      expect(rec.publicKeyHex, 'AB' * 32);
      expect(rec.type, 2);
      expect(rec.outPathLen, 2);
      expect(rec.routeBytes, [0x4E, 0x7A]);
      expect(rec.hasRoute, isTrue);
      expect(rec.name, 'Hilltop');
      expect(rec.lastAdvert, 1700000000);
      expect(rec.latMicro, 45269740);
      expect(rec.lonMicro, -75777460);
      expect(rec.lastMod, 1700000100);
      final frame = rec.toFrame(CommandCodes.addUpdateContact);
      expect(frame[0], CommandCodes.addUpdateContact);
      expect(frame.sublist(1), payload);
    });

    test('0xFF path length is no route', () {
      final rec = ContactRecord.parse(
          BufferReader(contactPayload(pubkey: key(1), outPathLen: 0xFF)));
      expect(rec.hasRoute, isFalse);
      expect(rec.routeBytes, isEmpty);
    });

    test('newRepeater builds a flood contact of type repeater', () {
      final rec = ContactRecord.newRepeater(
          publicKey: key(7),
          name: 'A name that is far too long for the thirty-two byte field',
          lat: 45.26974,
          lon: -75.77746,
          nowSecs: 1234);
      expect(rec.type, AdvTypes.repeater);
      expect(rec.outPathLen, ProtocolConstants.outPathUnknown);
      expect(rec.latMicro, 45269740);
      expect(rec.lonMicro, -75777460);
      expect(rec.lastAdvert, 1234);
      expect(rec.lastMod, 1234);
      final frame = rec.toFrame(CommandCodes.addUpdateContact);
      expect(frame.length, 1 + ContactRecord.payloadLength);
      // Name is truncated to 31 bytes plus NUL.
      expect(ContactRecord.parse(BufferReader(frame.sublist(1))).name.length,
          31);
    });

    test('a short payload throws FormatException', () {
      expect(() => ContactRecord.parse(BufferReader(Uint8List(100))),
          throwsFormatException);
    });
  });

  group('getContacts', () {
    test('collects CONTACT frames until END_OF_CONTACTS', () async {
      final future = connection.getContacts();
      await transport.settle();
      expect(transport.writes.length, 1);
      expect(transport.writes[0], [CommandCodes.getContacts, 0, 0, 0, 0]);

      transport.emit([ResponseCodes.contactsStart, 2, 0, 0, 0]);
      transport.emit(
          [ResponseCodes.contact, ...contactPayload(pubkey: key(1))]);
      transport.emit(
          [ResponseCodes.contact, ...contactPayload(pubkey: key(2))]);
      transport.emit([ResponseCodes.endOfContacts, 0, 0, 0, 0]);

      final contacts = await future;
      expect(contacts.map((c) => c.publicKeyHex).toList(),
          ['01' * 32, '02' * 32]);
    });

    test('ERR while iterating fails with the radio code', () async {
      final future = connection.getContacts();
      await transport.settle();
      transport.emit([ResponseCodes.err, ErrorCodes.badState]);
      await expectLater(
          future,
          throwsA(isA<RadioErrorException>()
              .having((e) => e.errorCode, 'code', ErrorCodes.badState)));
    });

    test('a second getContacts while one runs is refused', () async {
      final first = connection.getContacts();
      await transport.settle();
      expect(() => connection.getContacts(), throwsA(isA<StateError>()));
      transport.emit([ResponseCodes.contactsStart, 0, 0, 0, 0]);
      transport.emit([ResponseCodes.endOfContacts, 0, 0, 0, 0]);
      expect(await first, isEmpty);
    });

    test(
        'a write failure clears the completer so a later abort has no '
        'listener to yell at', () async {
      transport.failWrites = true;
      await expectLater(
          connection.getContacts(), throwsA(isA<StateError>()));
      // If the orphaned completer were still registered, disposing here
      // would call completeError on it with nobody awaiting the future,
      // which flutter_test reports as an unhandled asynchronous error and
      // fails this test.
      connection.dispose();
    });
  });

  group('addContact', () {
    test('writes the 148-byte frame and resolves on OK', () async {
      final rec = ContactRecord.newRepeater(
          publicKey: key(9), name: 'R', lat: 1, lon: 2, nowSecs: 5);
      final future = connection.addContact(rec);
      await transport.settle();
      expect(transport.writes.single.length, 148);
      expect(transport.commandAt(0), CommandCodes.addUpdateContact);
      transport.emit([ResponseCodes.ok]);
      await future;
    });

    test('ERR 3 is table full', () async {
      final rec = ContactRecord.newRepeater(
          publicKey: key(9), name: 'R', lat: 1, lon: 2, nowSecs: 5);
      final future = connection.addContact(rec);
      await transport.settle();
      transport.emit([ResponseCodes.err, ErrorCodes.tableFull]);
      await expectLater(
          future,
          throwsA(isA<RadioErrorException>()
              .having((e) => e.isTableFull, 'isTableFull', isTrue)));
    });

    test(
        'a write failure clears the completer so a later abort has no '
        'listener to yell at', () async {
      final rec = ContactRecord.newRepeater(
          publicKey: key(9), name: 'R', lat: 1, lon: 2, nowSecs: 5);
      transport.failWrites = true;
      await expectLater(
          connection.addContact(rec), throwsA(isA<StateError>()));
      // Same orphan-completer hazard as getContacts: a leftover
      // _adminOkCompleter would take disposal's completeError with no
      // listener, which flutter_test reports as an unhandled asynchronous
      // error and fails this test.
      connection.dispose();
    });
  });

  group('SENT', () {
    test('a 10-byte SENT still completes the legacy send completer', () async {
      final future = connection.sendChannelTextMessage(0, 1, 0, 'hi');
      await transport.settle();
      transport.emit(
          [ResponseCodes.sent, 1, 0xDE, 0xAD, 0xBE, 0xEF, 0x10, 0x27, 0, 0]);
      await future;
    });
  });
}
