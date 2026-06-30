import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/wire_tag_codec.dart';

/// Wire-tag codec contract. The tag now encodes the SESSION DATE as well, so a
/// `(region, NNNN, counter)` triple mints a DIFFERENT tag on a different day —
/// this is what makes a recycled daily NNNN globally unique (the "green TX →
/// DEAD tile" fix). The codec MUST stay byte-identical to the PHP
/// `wireTagEncode`/`wireTagDecode` twins — the pinned canonical vectors below
/// are the cross-language wire contract.
void main() {
  const key = 'TESTKEY';

  group('shape', () {
    test('tag is "MM:" + 10 base64url chars (13 chars; 7-byte payload)', () {
      final body = WireTagCodec.encode('PAR-20260611-0013', 1, key);
      expect(body.length, 13);
      expect(RegExp(r'^MM:[A-Za-z0-9_-]{10}$').hasMatch(body), isTrue);
    });

    test('same inputs are deterministic', () {
      expect(
        WireTagCodec.encode('PAR-20260611-0013', 7, key),
        WireTagCodec.encode('PAR-20260611-0013', 7, key),
      );
    });
  });

  group('date is encoded (the bug fix)', () {
    test('same region/NNNN/counter on DIFFERENT days mint DIFFERENT tags', () {
      final jun20 = WireTagCodec.encode('PAE-20260620-0007', 18, key);
      final jun21 = WireTagCodec.encode('PAE-20260621-0007', 18, key);
      expect(jun20, isNot(jun21),
          reason: 'recycled daily NNNN must not collide across days');
    });

    test('all six WX7RAW counters differ across the two days', () {
      for (var c = 18; c <= 23; c++) {
        expect(
          WireTagCodec.encode('PAE-20260620-0007', c, key),
          isNot(WireTagCodec.encode('PAE-20260621-0007', c, key)),
          reason: 'counter $c collided across days',
        );
      }
    });
  });

  group('key fallback', () {
    test('null key == empty-string key, and both differ from a real key', () {
      const sid = 'AAR-20260611-0123';
      expect(WireTagCodec.encode(sid, 5, null), WireTagCodec.encode(sid, 5, ''));
      expect(WireTagCodec.encode(sid, 5, null),
          isNot(WireTagCodec.encode(sid, 5, key)));
    });
  });

  group('decode recovers region / full date / session# / counter', () {
    test('a specific tag round-trips with the date intact', () {
      final body = WireTagCodec.encode('PAE-20260621-0007', 18, key);
      final d = WireTagCodec.decode(body, key);
      expect(d.region, 'PAE');
      expect(d.year, 2026);
      expect(d.month, 6);
      expect(d.day, 21);
      expect(d.sessionNum, 7);
      expect(d.counter, 18);
    });

    test('reconstructs the full session_id', () {
      final body = WireTagCodec.encode('YOW-20260504-0005', 42, key);
      final d = WireTagCodec.decode(body, key);
      final rebuilt =
          '${d.region}-${d.year.toString().padLeft(4, '0')}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}-${d.sessionNum.toString().padLeft(4, '0')}';
      expect(rebuilt, 'YOW-20260504-0005');
    });

    test('wrong key yields a different region', () {
      final body = WireTagCodec.encode('PAR-20260611-0013', 1, key);
      expect(WireTagCodec.decode(body, 'nope').region, isNot('PAR'));
    });
  });

  group('round-trip exactness (dates, NNNN, counters)', () {
    test('boundary dates and the 14-bit NNNN / 11-bit counter extremes', () {
      final cases = <(String, int)>[
        ('AAA-20200101-0001', 1), // epoch floor of the date field (year 2020)
        ('ZZZ-20831231-9999', 2047), // ceilings: year 2083, NNNN 9999, counter 2047
        ('PAE-20260101-0007', 1),
        ('PAE-20261231-0007', 2047),
        ('JKG-20260229-0009', 100), // leap day
      ];
      for (final (sid, c) in cases) {
        final d = WireTagCodec.decode(WireTagCodec.encode(sid, c, key), key);
        final p = sid.split('-');
        expect(d.region, p[0]);
        expect(d.year, int.parse(p[1].substring(0, 4)));
        expect(d.month, int.parse(p[1].substring(4, 6)));
        expect(d.day, int.parse(p[1].substring(6, 8)));
        expect(d.sessionNum, int.parse(p[2]));
        expect(d.counter, c);
      }
    });

    test('1..1000 counters all unique and exactly recovered', () {
      const sid = 'AAR-20260611-0123';
      final bodies = <String>{};
      for (var c = 1; c <= 1000; c++) {
        final body = WireTagCodec.encode(sid, c, key);
        bodies.add(body);
        final d = WireTagCodec.decode(body, key);
        expect(d.region, 'AAR');
        expect(d.year, 2026);
        expect(d.month, 6);
        expect(d.day, 11);
        expect(d.sessionNum, 123);
        expect(d.counter, c);
      }
      expect(bodies.length, 1000);
    });
  });

  // Cross-language canonical vectors — confirmed byte-identical to PHP
  // wireTagEncode (run MeshMapper_Server/wire_tag_codec.php on the same inputs).
  // These are the wire contract; changing the codec MUST regenerate both sides.
  group('canonical vectors (key=TESTKEY)', () {
    final vectors = <(String, int), String>{
      ('PAR-20260611-0013', 1): 'MM:YVNPAr5OIw',
      ('JKG-20260611-0009', 1): 'MM:_ZqTR9KmUQ',
      ('AAR-20260611-0014', 1): 'MM:xJkY4fMf0A',
      ('AAR-20260611-0123', 1000): 'MM:yPPRVhdweg',
      ('YOW-20260504-0005', 1): 'MM:q2REy6j1xQ',
      ('ZZZ-20260101-9999', 2047): 'MM:tbOGo9kJHg',
      ('PAE-20260620-0007', 18): 'MM:YPKG3YBefw',
      ('PAE-20260621-0007', 18): 'MM:gCXS1s-0ew', // same NNNN/counter, next day → different tag
      ('AAA-20200101-0001', 1): 'MM:mcvZkYjWyw',
      ('ZZZ-20831231-9999', 2047): 'MM:lT-SF6aZAw',
    };
    vectors.forEach((input, expected) {
      test('${input.$1} ping ${input.$2} -> $expected', () {
        expect(WireTagCodec.encode(input.$1, input.$2, key), expected);
      });
    });
  });

  group('canonical vectors (empty-key fallback)', () {
    final vectors = <(String, int), String>{
      ('PAR-20260611-0013', 1): 'MM:sYVCDwfmyg',
      ('JKG-20260611-0009', 1): 'MM:KzK7sA1D2w',
      ('AAR-20260611-0014', 1): 'MM:5KWUc6SGLQ',
      ('AAR-20260611-0123', 1000): 'MM:XVn2vjKTzQ',
      ('YOW-20260504-0005', 1): 'MM:UIcMpMVBng',
      ('ZZZ-20260101-9999', 2047): 'MM:f9QkqSCBKg',
      ('PAE-20260620-0007', 18): 'MM:NWGgGQHdUg',
      ('PAE-20260621-0007', 18): 'MM:bhBWfbLBfg',
      ('AAA-20200101-0001', 1): 'MM:GlX5oUogpg',
      ('ZZZ-20831231-9999', 2047): 'MM:v7UAnOrSZw',
    };
    vectors.forEach((input, expected) {
      test('null/empty key, ${input.$1} ping ${input.$2} -> $expected', () {
        expect(WireTagCodec.encode(input.$1, input.$2, null), expected);
        expect(WireTagCodec.encode(input.$1, input.$2, ''), expected);
      });
    });
  });
}
