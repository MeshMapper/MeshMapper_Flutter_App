import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/wire_tag_codec.dart';

/// Canonical cross-language vectors. These MUST stay byte-identical to the PHP
/// `wireTagEncode` and the Python reference oracle — they are the wire contract.
/// See docs / the TX Wire-Tag plan for how they were generated.
void main() {
  group('WireTagCodec.encode (canonical vectors, key=TESTKEY)', () {
    const key = 'TESTKEY';
    final vectors = <(String, int), String>{
      ('PAR-20260611-0013', 1): 'MM:zpCFQwc',
      ('JKG-20260611-0009', 1): 'MM:zJHa-B8',
      ('AAR-20260611-0014', 1): 'MM:GD59I2Q',
      ('AAR-20260611-0123', 1000): 'MM:x6laqiY',
      ('YOW-20260504-0005', 1): 'MM:2Oj9Xyg',
      ('ZZZ-20260101-9999', 2047): 'MM:ETfo5FI',
    };

    vectors.forEach((input, expected) {
      test('${input.$1} ping ${input.$2} -> $expected', () {
        expect(WireTagCodec.encode(input.$1, input.$2, key), expected);
      });
    });

    test('body is always "MM:" + 7 base64url chars (10 chars, one AES block)', () {
      final body = WireTagCodec.encode('PAR-20260611-0013', 1, key);
      expect(body.length, 10);
      expect(RegExp(r'^MM:[A-Za-z0-9_-]{7}$').hasMatch(body), isTrue);
    });
  });

  group('WireTagCodec.encode (empty-key fallback)', () {
    final vectors = <(String, int), String>{
      ('PAR-20260611-0013', 1): 'MM:jHHz-gQ',
      ('JKG-20260611-0009', 1): 'MM:ozT0SI8',
      ('AAR-20260611-0014', 1): 'MM:4y-cINQ',
      ('AAR-20260611-0123', 1000): 'MM:ATsK8_8',
      ('YOW-20260504-0005', 1): 'MM:EiC-3p4',
      ('ZZZ-20260101-9999', 2047): 'MM:_CI9Xfs',
    };

    vectors.forEach((input, expected) {
      test('null key == "" key, ${input.$1} ping ${input.$2} -> $expected', () {
        expect(WireTagCodec.encode(input.$1, input.$2, null), expected);
        expect(WireTagCodec.encode(input.$1, input.$2, ''), expected);
      });
    });
  });

  group('WireTagCodec.decode (key only, no DB)', () {
    test('recovers region/session#/counter from a known body', () {
      final r = WireTagCodec.decode('MM:zpCFQwc', 'TESTKEY');
      expect(r.region, 'PAR');
      expect(r.sessionNum, 13);
      expect(r.counter, 1);
    });

    test('decode with the wrong key yields a different region', () {
      final right = WireTagCodec.decode('MM:zpCFQwc', 'TESTKEY');
      final wrong = WireTagCodec.decode('MM:zpCFQwc', 'nope');
      expect(right.region, 'PAR');
      expect(wrong.region, isNot('PAR'));
    });
  });

  group('round-trip exactness across ping 1..1000', () {
    test('encode then decode recovers the exact triple, all unique', () {
      const key = 'TESTKEY';
      const sid = 'AAR-20260611-0123';
      final bodies = <String>{};
      for (var c = 1; c <= 1000; c++) {
        final body = WireTagCodec.encode(sid, c, key);
        bodies.add(body);
        final d = WireTagCodec.decode(body, key);
        expect(d.region, 'AAR');
        expect(d.sessionNum, 123);
        expect(d.counter, c);
      }
      expect(bodies.length, 1000, reason: 'every ping must be unique on the wire');
    });
  });
}
