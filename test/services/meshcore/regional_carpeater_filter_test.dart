import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/regional_carpeater_filter.dart';

/// The region's shared CARpeater list. A path hop (2, 4 or 6 hex) matches on
/// its own width, a discovery key matches exactly, and the user's own key is
/// counted but never dropped (it keeps the pass-through behaviour).
void main() {
  final a = 'AB' * 32; // hop AB / ABAB / ABABAB
  final b = 'CD' * 32;
  final own = 'EF' * 32;

  group('sanitize', () {
    test('keeps only full keys, upper-cased, deduplicated and sorted', () {
      final keys = RegionalCarpeaterFilter.sanitize([
        b.toLowerCase(),
        'junk',
        42,
        null,
        a,
        b,
        '0x$a',
      ]);
      expect(keys, [a, b]);
    });

    test('anything that is not a list is an empty list', () {
      expect(RegionalCarpeaterFilter.sanitize(null), isEmpty);
      expect(RegionalCarpeaterFilter.sanitize('nope'), isEmpty);
      expect(RegionalCarpeaterFilter.sanitize({'a': 1}), isEmpty);
    });
  });

  group('own key', () {
    test('is counted but excluded from the drop set', () {
      final f = RegionalCarpeaterFilter(keys: [a, own], ownKey: own);
      expect(f.count, 2);
      expect(f.dropSet, {a});
      expect(f.matchesKey(own), isFalse);
      expect(f.matchesHop('EF'), isFalse);
    });

    test('an own key that is not a full key is ignored', () {
      final f = RegionalCarpeaterFilter(keys: [a], ownKey: 'AB');
      expect(f.ownKey, isNull);
      expect(f.dropSet, {a});
    });
  });

  group('matchesHop', () {
    final f = RegionalCarpeaterFilter(keys: [a, b]);

    test('matches a hop on its own width', () {
      expect(f.matchesHop('AB'), isTrue);
      expect(f.matchesHop('ABAB'), isTrue);
      expect(f.matchesHop('ABABAB'), isTrue);
      expect(f.matchesHop('CDCD'), isTrue);
    });

    test('a prefix that diverges does not match', () {
      expect(f.matchesHop('AC'), isFalse);
      expect(f.matchesHop('ABAC'), isFalse);
      expect(f.matchesHop('ABABAC'), isFalse);
    });

    test('is case-insensitive and refuses junk', () {
      expect(f.matchesHop('abab'), isTrue);
      expect(f.matchesHop(''), isFalse);
      expect(f.matchesHop('ZZ'), isFalse);
      expect(f.matchesHop('${a}AB'), isFalse);
    });

    test('an empty list never matches', () {
      final empty = RegionalCarpeaterFilter();
      expect(empty.matchesHop('AB'), isFalse);
      expect(empty.matchesKey(a), isFalse);
      expect(empty.count, 0);
    });
  });

  group('matchesKey', () {
    final f = RegionalCarpeaterFilter(keys: [a]);

    test('matches the full key only, any case', () {
      expect(f.matchesKey(a), isTrue);
      expect(f.matchesKey(a.toLowerCase()), isTrue);
      expect(f.matchesKey(b), isFalse);
      expect(f.matchesKey('AB'), isFalse);
      expect(f.matchesKey(a.substring(0, 62)), isFalse);
    });
  });
}
