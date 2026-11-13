import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/utils/short_hop_ids.dart';

/// A full 64-hex public key that starts with [prefix].
String _key(String prefix) => prefix.toUpperCase().padRight(64, '0');

Repeater _repeater(String hexId, {String id = '', int advertBytes = 3}) =>
    Repeater(
      id: id,
      hexId: hexId,
      name: 'Rep',
      lat: 59.3,
      lon: 18.0,
      lastHeard: 1787535900,
      enabled: 1,
      hopBytes: advertBytes,
      advertBytes: advertBytes,
    );

void main() {
  final norra = _repeater(_key('A81EA4'));
  final other = _repeater(_key('B7C2D9'));

  group('resolve', () {
    test('a unique 1-byte prefix resolves to its repeater', () {
      final index = ShortHopIds.fromRepeaters([norra, other]);
      expect(index.resolve('A8'), same(norra));
    });

    test('a unique 2-byte prefix resolves to its repeater', () {
      final index = ShortHopIds.fromRepeaters([norra, other]);
      expect(index.resolve('A81E'), same(norra));
    });

    test('a prefix two repeaters share stays unresolved', () {
      final twin = _repeater(_key('A8FF01'));
      final index = ShortHopIds.fromRepeaters([norra, twin, other]);
      expect(index.resolve('A8'), isNull);
      expect(index.resolve('A81E'), same(norra));
    });

    test('a prefix no repeater has stays unresolved', () {
      final index = ShortHopIds.fromRepeaters([norra, other]);
      expect(index.resolve('C4'), isNull);
    });

    test('matching ignores case', () {
      final index =
          ShortHopIds.fromRepeaters([_repeater(_key('a81ea4').toLowerCase())]);
      expect(index.resolve('a8'), isNotNull);
      expect(index.resolve('A8'), isNotNull);
    });

    test('rows of the same device in a prefix chain are one repeater', () {
      // A legacy row that only has a short id, plus the full-key row.
      final legacy = _repeater('', id: 'a81e');
      final index = ShortHopIds.fromRepeaters([legacy, norra]);
      expect(index.resolve('A8'), same(norra));
    });

    test('a repeater with no hex is never a candidate', () {
      final blank = _repeater('', id: '');
      final index = ShortHopIds.fromRepeaters([blank, norra]);
      expect(index.resolve('A8'), same(norra));
    });

    test('a prefix of an unindexed length still resolves', () {
      final index = ShortHopIds.fromRepeaters([norra, other]);
      expect(index.resolve('A81EA'), same(norra));
      expect(index.resolve('A81EA400'), same(norra));
    });

    test('rejects non-hex and too-short ids', () {
      final index = ShortHopIds.fromRepeaters([norra]);
      expect(index.resolve('A'), isNull);
      expect(index.resolve(''), isNull);
      expect(index.resolve('ZZ'), isNull);
    });
  });

  group('matching', () {
    final twin = _repeater(_key('A8FF01'));
    final index = ShortHopIds.fromRepeaters([norra, twin, other]);

    test('lists every repeater whose key starts with the id', () {
      expect(index.matching('A8'), [norra, twin]);
      expect(index.matching('a81e'), [norra]);
      expect(index.matching(_key('A8FF01')), [twin]);
    });

    test('an id that only shares a first byte matches nothing', () {
      expect(index.matching('A81EFF'), isEmpty);
      expect(index.matching('A8D4'), isEmpty);
    });

    test('unknown, non-hex and too-short ids match nothing', () {
      expect(index.matching('C4'), isEmpty);
      expect(index.matching('ZZ'), isEmpty);
      expect(index.matching('A'), isEmpty);
    });
  });

  group('displayId', () {
    test('a short id shows as the full-width id of its one match', () {
      final index = ShortHopIds.fromRepeaters([norra, other]);
      expect(index.displayId('A8', hopBytes: 1), 'A81EA4');
      expect(index.displayId('a81e', hopBytes: 1), 'A81EA4');
    });

    test('the region width widens a repeater that advertises narrower', () {
      final narrow = _repeater(_key('A81EA4'), advertBytes: 1);
      final index = ShortHopIds.fromRepeaters([narrow]);
      expect(index.displayId('A8', hopBytes: 1), 'A8');
      expect(index.displayId('A8', hopBytes: 3), 'A81EA4');
    });

    test('a full-length id is unchanged', () {
      final index = ShortHopIds.fromRepeaters([norra, other]);
      expect(index.displayId('A81EA4', hopBytes: 3), 'A81EA4');
      expect(index.displayId('a81ea4', hopBytes: 3), 'A81EA4');
    });

    test('an ambiguous or unknown id is unchanged', () {
      final twin = _repeater(_key('A8FF01'));
      final index = ShortHopIds.fromRepeaters([norra, twin]);
      expect(index.displayId('A8', hopBytes: 3), 'A8');
      expect(index.displayId('C4', hopBytes: 3), 'C4');
    });
  });

  group('bestSnrByRepeater', () {
    test('Top Heard merges a short id and the full id into one row', () {
      final index = ShortHopIds.fromRepeaters([norra, other]);
      final rows = index.bestSnrByRepeater([
        (repeaterId: 'A81EA4', snr: 0.0),
        (repeaterId: 'A8', snr: -6.0),
        (repeaterId: 'B7C2D9', snr: 3.0),
      ], hopBytes: 3);
      expect(rows, {'A81EA4': 0.0, 'B7C2D9': 3.0});
    });

    test('an ambiguous short id keeps its own row', () {
      final twin = _repeater(_key('A8FF01'));
      final index = ShortHopIds.fromRepeaters([norra, twin]);
      final rows = index.bestSnrByRepeater([
        (repeaterId: 'A81EA4', snr: 0.0),
        (repeaterId: 'A8', snr: 2.0),
      ], hopBytes: 3);
      expect(rows, {'A81EA4': 0.0, 'A8': 2.0});
    });
  });
}
