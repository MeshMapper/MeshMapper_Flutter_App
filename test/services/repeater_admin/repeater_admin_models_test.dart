import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_models.dart';

void main() {
  group('hex helpers', () {
    test('round trip and case', () {
      final b = hexToBytes('ab01FF');
      expect(b, [0xAB, 0x01, 0xFF]);
      expect(bytesToHex(b), 'AB01FF');
    });
    test('odd length throws', () {
      expect(() => hexToBytes('abc'), throwsFormatException);
    });
    test('a non-hex character throws', () {
      expect(() => hexToBytes('-1'), throwsFormatException);
      expect(() => hexToBytes(' 1'), throwsFormatException);
      expect(() => hexToBytes('+1'), throwsFormatException);
      expect(() => hexToBytes('zz'), throwsFormatException);
    });
  });

  group('RepeaterTarget', () {
    final rep = Repeater(
        id: '4E', hexId: 'ab' * 32, name: 'Hill', lat: 1.5, lon: -2.5,
        lastHeard: 0, enabled: 1);
    test('from a repeater with a full key', () {
      final t = RepeaterTarget.fromRepeater(rep);
      expect(t.hexId, 'AB' * 32);
      expect(t.shortId, 'ABABABAB');
      expect(t.name, 'Hill');
    });
    test('a short key is refused', () {
      expect(
          () => RepeaterTarget.fromRepeater(const Repeater(
              id: '4E', hexId: 'AB12', name: 'x', lat: 0, lon: 0,
              lastHeard: 0, enabled: 1)),
          throwsArgumentError);
    });
  });

  group('RepeaterRoute', () {
    test('splits hops by width', () {
      final r = RepeaterRoute.fromRouteBytes(
          Uint8List.fromList([0x4E, 0x7A, 0x3B, 0x00]), hopBytes: 2);
      expect(r.flood, isFalse);
      expect(r.hops, ['4E7A', '3B00']);
    });
    test('falls back to one-byte hops on a width mismatch', () {
      final r = RepeaterRoute.fromRouteBytes(
          Uint8List.fromList([0x4E, 0x7A, 0x3B]), hopBytes: 2);
      expect(r.hops, ['4E', '7A', '3B']);
    });
    test('empty bytes is a direct route', () {
      final r = RepeaterRoute.fromRouteBytes(Uint8List(0), hopBytes: 1);
      expect(r.flood, isFalse);
      expect(r.direct, isTrue);
      expect(r.describe((_) => null), 'Direct (no hops)');
    });
    test('flood describes as flood', () {
      const r = RepeaterRoute.flood();
      expect(r.direct, isFalse);
      expect(r.describe((_) => null), 'Flood (no route learned yet)');
    });
    test('describe resolves names else hex', () {
      const r = RepeaterRoute(hops: ['4E', '7A'], flood: false);
      expect(r.describe((h) => h == '4E' ? 'Hill' : null), 'Hill > 7A');
    });
  });

  group('access list', () {
    test('parses entries and the admin bit', () {
      final data = Uint8List.fromList([
        1, 2, 3, 4, 5, 6, 3, // admin
        9, 9, 9, 9, 9, 9, 0, // guest
      ]);
      final acl = parseAccessList(data);
      expect(acl.entries.length, 2);
      expect(acl.entries[0].isAdmin, isTrue);
      expect(acl.entries[1].isAdmin, isFalse);
      expect(acl.entries[0].prefix, [1, 2, 3, 4, 5, 6]);
    });
    test('a trailing partial entry is ignored', () {
      final acl = parseAccessList(Uint8List.fromList([1, 2, 3]));
      expect(acl.entries, isEmpty);
    });
    test('an empty reply is an empty list', () {
      expect(parseAccessList(Uint8List(0)).entries, isEmpty);
    });
    test('the reply body starts at the first entry, there is no timestamp', () {
      // The 28-byte reply a repeater answered on 2026-09-10: four entries,
      // every one with perms 0x03. Skipping a timestamp read three entries
      // with perms 0xEB, 0xF8 and 0x2B out of the middle of the keys.
      final acl = parseAccessList(Uint8List.fromList([
        0x84, 0x82, 0xe6, 0x18, 0x80, 0xc6, 0x03,
        0xa6, 0x07, 0xb2, 0xeb, 0xf3, 0x1b, 0x03,
        0x1c, 0x96, 0x6a, 0xf8, 0x91, 0x79, 0x03,
        0x27, 0xb9, 0xe9, 0x2b, 0x5a, 0xe1, 0x03,
      ]));
      expect(acl.entries.length, 4);
      expect(acl.entries.every((e) => e.isAdmin), isTrue);
      expect(acl.entries[0].prefix, [0x84, 0x82, 0xe6, 0x18, 0x80, 0xc6]);
    });
    test('request bytes', () {
      expect(buildAccessListRequest(), [0x05, 0, 0]);
    });
  });

  group('neighbour page', () {
    test('parses the header and the entries with int8/4 SNR', () {
      final data = Uint8List.fromList([
        25, 0, // total
        2, 0, // returned
        ...List<int>.filled(8, 0xAB), 10, 0, 0, 0, 0xFC, // heard 10 s, -1.0 dB
        ...List<int>.filled(8, 0xCD), 0x10, 0x27, 0, 0, 10, // heard 10000 s, +2.5 dB
      ]);
      final page = parseNeighbourPage(data, prefixLen: 8);
      expect(page.total, 25);
      expect(page.returned, 2);
      expect(page.entries.length, 2);
      expect(page.entries[0].prefixHex, 'AB' * 8);
      expect(page.entries[0].heardSecsAgo, 10);
      expect(page.entries[0].snrDb, -1.0);
      expect(page.entries[0].name, isNull);
      expect(page.entries[1].prefixHex, 'CD' * 8);
      expect(page.entries[1].heardSecsAgo, 10000);
      expect(page.entries[1].snrDb, 2.5);
    });
    test('a trailing partial entry is ignored', () {
      final data = Uint8List.fromList([
        1, 0, 1, 0, ...List<int>.filled(8, 1), 1, 0,
      ]);
      expect(parseNeighbourPage(data, prefixLen: 8).entries, isEmpty);
    });
    test('shorter than 4 bytes throws', () {
      expect(() => parseNeighbourPage(Uint8List(3), prefixLen: 8),
          throwsFormatException);
    });
    test('a real page: header, entries, cipher padding ignored', () {
      // The first page CBC-FORTUNE-R1 answered on 2026-09-10 (140 bytes as
      // handed over by sendBinaryRequest): 50 known, 10 returned, then the
      // six zero bytes of cipher padding. Skipping a timestamp read the
      // total as 43799 and the first prefix as 2ACA255E4D000000.
      final data = Uint8List.fromList([
        0x32, 0x00, 0x0a, 0x00,
        0x17, 0xab, 0x75, 0x37, 0x2a, 0xca, 0x25, 0x5e, 0x45, 0, 0, 0, 0x22,
        0xa0, 0x1e, 0x36, 0x76, 0x25, 0xd0, 0x89, 0x8a, 0x4d, 0, 0, 0, 0xfa,
        0xe1, 0xad, 0x61, 0xe9, 0x22, 0x72, 0x02, 0xe6, 0x8c, 0, 0, 0, 0xf6,
        0x0d, 0xf4, 0xb2, 0xe5, 0x22, 0x7d, 0x14, 0xb8, 0xda, 0, 0, 0, 0xef,
        0xb9, 0x47, 0x19, 0x42, 0x37, 0x02, 0x30, 0xfd, 0xe7, 0, 0, 0, 0x29,
        0xb1, 0xfb, 0xd6, 0xaa, 0x2b, 0x0e, 0xb5, 0x70, 0xea, 0, 0, 0, 0x28,
        0x22, 0xeb, 0xc5, 0xeb, 0xb5, 0xcc, 0x7d, 0xc5, 0x3a, 1, 0, 0, 0x28,
        0xcd, 0x9c, 0xb3, 0x65, 0x71, 0x12, 0x9e, 0x9a, 0x02, 2, 0, 0, 0xee,
        0x8e, 0xe9, 0x3b, 0x76, 0x5d, 0xc1, 0x01, 0x9f, 0xc4, 4, 0, 0, 0x31,
        0xee, 0x5f, 0x1f, 0x8e, 0xa6, 0xa9, 0x19, 0xed, 0xc2, 6, 0, 0, 0xef,
        0, 0, 0, 0, 0, 0,
      ]);
      final page = parseNeighbourPage(data, prefixLen: 8);
      expect(page.total, 50);
      expect(page.returned, 10);
      expect(page.entries.length, 10);
      expect(page.entries[0].prefixHex, '17AB75372ACA255E');
      expect(page.entries[0].heardSecsAgo, 69);
      expect(page.entries[0].snrDb, 8.5);
      expect(page.entries[1].snrDb, -1.5);
      expect(page.entries[9].prefixHex, 'EE5F1F8EA6A919ED');
      expect(page.entries[9].heardSecsAgo, 0x06c2);
    });
    test('request bytes: type, version, count, offset LE, order, prefix, random', () {
      final req = buildNeighbourRequest(offset: 0x0102, random: 0x04030201);
      expect(req, [0x06, 0, 10, 0x02, 0x01, 0, 8, 0x01, 0x02, 0x03, 0x04]);
      expect(buildNeighbourRequest(offset: 0, random: 0, count: 5, prefixLen: 4)
          .sublist(0, 7), [0x06, 0, 5, 0, 0, 0, 4]);
    });
    test('withName and toWire', () {
      final n = RepeaterNeighbour(prefixHex: 'AB' * 8, heardSecsAgo: 3, snrDb: -1.5);
      expect(n.withName('Hill').name, 'Hill');
      expect(n.withName(null).name, isNull);
      expect(n.toWire(), {'prefix': 'AB' * 8, 'snr': -1.5, 'heard_secs_ago': 3});
    });
  });

  group('AdminProof', () {
    test('toWire is the claim proof', () {
      const proof = AdminProof(
          loginAdmin: true, aclConfirmed: true, aclPerms: 3, fwLevel: 2,
          aclEntries: 1, ownEntryIsAdmin: true);
      expect(proof.isProven, isTrue);
      expect(proof.toWire(), {'login': 'admin', 'acl': true, 'perms': 3, 'fw_level': 2});
    });
    test('unanswered ACL is not proven', () {
      const proof = AdminProof(
          loginAdmin: true, aclConfirmed: false, aclEntries: 0, ownEntryIsAdmin: false);
      expect(proof.isProven, isFalse);
      expect(proof.toWire(), {'login': 'admin', 'acl': false, 'perms': 0, 'fw_level': null});
    });
  });

  group('RepeaterClaim', () {
    test('json round trip', () {
      final c = RepeaterClaim.fromJson({
        'repeater': 'cd' * 32, 'name': 'Hill', 'iata': 'YOW',
        'claimed_at': 1, 'updated_at': 2,
      });
      expect(c.repeaterHex, 'CD' * 32);
      expect(c.name, 'Hill');
      expect(c.iata, 'YOW');
      expect(c.claimedAt, 1);
      expect(c.updatedAt, 2);
      expect(RepeaterClaim.fromJson(c.toJson()).toJson(), c.toJson());
    });
    test('tryFromJson drops a bad key and tolerates missing fields', () {
      expect(RepeaterClaim.tryFromJson({'repeater': 'nope'}), isNull);
      expect(RepeaterClaim.tryFromJson({'name': 'x'}), isNull);
      final c = RepeaterClaim.tryFromJson({'repeater': 'ef' * 32})!;
      expect(c.name, '');
      expect(c.iata, isNull);
      expect(c.claimedAt, 0);
      expect(c.updatedAt, 0);
    });
    test('fromJson throws on a bad key', () {
      expect(() => RepeaterClaim.fromJson({'repeater': 'nope'}), throwsFormatException);
    });
  });

  test('RepeaterAdminFailure carries a sentence', () {
    const f = RepeaterAdminFailure('Nope.');
    expect(f.message, 'Nope.');
    expect(f.toString(), contains('Nope.'));
  });

  test('constants', () {
    expect(kNeighbourPageSize, 10);
    expect(kNeighbourPrefixLen, 8);
    expect(kNeighbourMaxPages, 30);
    expect(kNeighbourUploadCap, 300);
  });
}
