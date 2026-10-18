import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/utils/repeater_nicknames.dart';

/// A full 64-hex public key that starts with [prefix].
String _key(String prefix) => prefix.toUpperCase().padRight(64, '0');

Repeater _repeater(
  String id,
  String hexId, {
  int hopBytes = 1,
  String name = 'Rep',
}) =>
    Repeater(
      id: id,
      hexId: hexId,
      name: name,
      lat: 47.6,
      lon: -122.3,
      lastHeard: 1787535900,
      enabled: 1,
      hopBytes: hopBytes,
    );

RepeaterNickname _nick(String nickname,
        {String name = 'Rep', String hex = ''}) =>
    RepeaterNickname(nickname: nickname, name: name, hex: hex);

void main() {
  group('normalizeNickname', () {
    test('trims and collapses whitespace runs to one space', () {
      expect(RepeaterNicknames.normalizeNickname('  Mell  '), 'Mell');
      expect(RepeaterNicknames.normalizeNickname('Me  Kr'), 'Me Kr');
      expect(RepeaterNicknames.normalizeNickname('Me\t\n Kr'), 'Me Kr');
    });

    test('caps at ${RepeaterNicknames.maxLength} characters', () {
      expect(RepeaterNicknames.maxLength, 8);
      expect(RepeaterNicknames.normalizeNickname('ABCDEFGHIJ'), 'ABCDEFGH');
      expect(RepeaterNicknames.normalizeNickname('ABCDEFGH'), 'ABCDEFGH');
    });

    test('a cap that lands on a space leaves no trailing space', () {
      final once = RepeaterNicknames.normalizeNickname('abcdefg hij');
      expect(once, 'abcdefg');
      expect(RepeaterNicknames.normalizeNickname(once), once,
          reason: 'normalizing a stored nickname again must not change it');
    });

    test('blank and null give null', () {
      expect(RepeaterNicknames.normalizeNickname('   '), isNull);
      expect(RepeaterNicknames.normalizeNickname(''), isNull);
      expect(RepeaterNicknames.normalizeNickname('\t\n'), isNull);
      expect(RepeaterNicknames.normalizeNickname(null), isNull);
    });

    test('a nickname nobody could see is blank', () {
      expect(RepeaterNicknames.normalizeNickname('\u200B\u200B'), isNull);
      expect(RepeaterNicknames.normalizeNickname('\u200D'), isNull);
      expect(RepeaterNicknames.normalizeNickname('\u200E \uFEFF'), isNull);
    });

    test('zero-width spaces are dropped from a visible nickname', () {
      expect(RepeaterNicknames.normalizeNickname('\u200BMe\u200Bll'), 'Mell');
    });

    test('counts user-perceived characters, not code units', () {
      // Each smiley is two UTF-16 code units; a code-unit cap would keep four.
      expect(RepeaterNicknames.normalizeNickname('😀' * 10), '😀' * 8);

      // A family emoji is seven code points joined by zero-width joiners but
      // one character to the user.
      const family = '👨‍👩‍👧';
      expect(RepeaterNicknames.normalizeNickname(family * 9), family * 8);

      // A combining accent is a separate code point on the letter before it.
      const accented = 'é';
      expect(RepeaterNicknames.normalizeNickname(accented * 10), accented * 8);
    });
  });

  group('sanitize', () {
    final keyA = _key('5007');

    test('keeps a valid entry', () {
      final out = RepeaterNicknames.sanitize({
        keyA: {'nickname': 'Mell', 'name': 'Capitol Hill', 'hex': '5007'},
      });

      expect(out, {
        keyA: _nick('Mell', name: 'Capitol Hill', hex: '5007'),
      });
    });

    test('normalizes the key from lower case and from a 0x prefix', () {
      final out = RepeaterNicknames.sanitize({
        keyA.toLowerCase(): {'nickname': 'Mell', 'name': 'A', 'hex': '5007'},
        '0x${_key('9c12').toLowerCase()}': {
          'nickname': 'Kr',
          'name': 'B',
          'hex': '9C12',
        },
      });

      expect(out.keys, unorderedEquals([keyA, _key('9c12')]));
      expect(out[keyA]?.nickname, 'Mell');
      expect(out[_key('9c12')]?.nickname, 'Kr');
    });

    test('drops a short key, a blank nickname and a non-map value', () {
      final out = RepeaterNicknames.sanitize({
        '5007': {'nickname': 'Short', 'name': 'A', 'hex': '5007'},
        _key('1111'): {'nickname': '   ', 'name': 'B', 'hex': '1111'},
        _key('2222'): 'Mell',
        _key('3333'): null,
        _key('4444'): {'nickname': 'Keep', 'name': 'C', 'hex': '4444'},
      });

      expect(out.keys, [_key('4444')]);
    });

    test('tolerates garbage without throwing', () {
      expect(RepeaterNicknames.sanitize(null), isEmpty);
      expect(RepeaterNicknames.sanitize('nope'), isEmpty);
      expect(RepeaterNicknames.sanitize(['a', 'b']), isEmpty);
      expect(RepeaterNicknames.sanitize(42), isEmpty);

      final out = RepeaterNicknames.sanitize(<dynamic, dynamic>{
        7: {'nickname': 'IntKey', 'name': 'A', 'hex': 'A'},
        _key('5555'): {'nickname': 9, 'name': 'B', 'hex': 'B'},
        _key('6666'): {'nickname': 'Fine', 'name': 12, 'hex': null},
      });

      expect(out.keys, [_key('6666')]);
      expect(out[_key('6666')], _nick('Fine', name: '', hex: '6666'),
          reason: 'a non-string name falls back to empty, a non-string hex '
              'to the key prefix');
    });

    test('a missing or blank hex falls back to the key prefix', () {
      final out = RepeaterNicknames.sanitize({
        _key('7A7A'): {'nickname': 'NoHex', 'name': 'A'},
        _key('8B8B'): {'nickname': 'Blank', 'name': 'B', 'hex': '  '},
      });

      expect(out[_key('7A7A')]?.hex, '7A7A');
      expect(out[_key('8B8B')]?.hex, '8B8B');
    });

    test('re-caps a stored nickname that is too long', () {
      final out = RepeaterNicknames.sanitize({
        keyA: {'nickname': '  ABCDEFGHIJ  ', 'name': 'A', 'hex': '5007'},
      });

      expect(out[keyA]?.nickname, 'ABCDEFGH');
    });
  });

  test('toStorage round-trips through sanitize', () {
    final nicknames = {
      _key('5007'): _nick('Mell', name: 'Capitol Hill', hex: '5007'),
      _key('9C12'): _nick('Me Kr', name: 'Queen Anne', hex: '9C12'),
    };

    final stored = RepeaterNicknames.toStorage(nicknames);

    expect(stored[_key('5007')], {
      'nickname': 'Mell',
      'name': 'Capitol Hill',
      'hex': '5007',
    });
    expect(RepeaterNicknames.sanitize(stored), nicknames);
  });

  group('nicknameFor', () {
    final keyA = _key('5007');
    final nicknames = {keyA: _nick('Mell')};

    test('matches a repeater whose hexId is lower case', () {
      expect(
        RepeaterNicknames.nicknameFor(
            _repeater('r1', keyA.toLowerCase()), nicknames),
        'Mell',
      );
      expect(
        RepeaterNicknames.nicknameFor(_repeater('r1', keyA), nicknames),
        'Mell',
      );
    });

    test('returns null for an empty or short hexId', () {
      expect(
        RepeaterNicknames.nicknameFor(
            _repeater('r1', ''), {'': _nick('Ghost'), ...nicknames}),
        isNull,
        reason: 'an empty key in the map must not name a repeater with no key',
      );
      expect(
        RepeaterNicknames.nicknameFor(_repeater('r1', '5007'), nicknames),
        isNull,
        reason: 'a short hexId is not a unique identity',
      );
    });

    test('returns null for a repeater with no nickname', () {
      expect(
        RepeaterNicknames.nicknameFor(_repeater('r2', _key('9C12')), nicknames),
        isNull,
      );
    });
  });

  group('labelFor', () {
    // Two repeaters share the leading byte 50, so a one-byte hash cannot tell
    // them apart. Their two-byte hashes differ.
    final keyMell = _key('5007');
    final keyOther = _key('5099');
    final mell = _repeater('r1', keyMell, hopBytes: 2, name: 'Capitol Hill');
    final other = _repeater('r2', keyOther, hopBytes: 2, name: 'Queen Anne');
    final nicknames = {keyMell: _nick('Mell', name: 'Capitol Hill')};

    test('a unique 2-byte display hash gives the nickname', () {
      expect(
        RepeaterNicknames.labelFor(
          displayId: '5007',
          repeaters: [mell, other],
          hopBytes: 2,
          nicknames: nicknames,
        ),
        'Mell',
      );
      expect(
        RepeaterNicknames.labelFor(
          displayId: '5007'.toLowerCase(),
          repeaters: [mell, other],
          hopBytes: 2,
          nicknames: nicknames,
        ),
        'Mell',
        reason: 'the display hash is matched case-insensitively',
      );
    });

    test('a 1-byte hash shared by two repeaters gives null', () {
      expect(
        RepeaterNicknames.labelFor(
          displayId: '50',
          repeaters: [mell, other],
          hopBytes: 1,
          nicknames: nicknames,
        ),
        isNull,
        reason: 'a confidently wrong name is worse than none',
      );
    });

    test("the shared hash plus one repeater's discovery key names it", () {
      expect(
        RepeaterNicknames.labelFor(
          displayId: '50',
          identity: keyMell,
          repeaters: [mell, other],
          hopBytes: 1,
          nicknames: nicknames,
        ),
        'Mell',
      );
      expect(
        RepeaterNicknames.labelFor(
          displayId: '50',
          identity: keyOther,
          repeaters: [mell, other],
          hopBytes: 1,
          nicknames: nicknames,
        ),
        isNull,
        reason: 'the other repeater resolves but has no nickname',
      );
    });

    test('an identity that resolves to nothing falls back to the hash', () {
      expect(
        RepeaterNicknames.labelFor(
          displayId: '5007',
          identity: _key('FFFF'),
          repeaters: [mell, other],
          hopBytes: 2,
          nicknames: nicknames,
        ),
        'Mell',
      );
    });

    test('a repeater with an empty hexId is never matched', () {
      final noHex = _repeater('50', '', name: 'Site Without Hex');

      expect(
        RepeaterNicknames.labelFor(
          displayId: '50',
          repeaters: [noHex],
          hopBytes: 1,
          nicknames: {'': _nick('Ghost'), ...nicknames},
        ),
        isNull,
        reason: 'it resolves by its short id, but a nickname needs a full key',
      );
      expect(
        RepeaterNicknames.labelFor(
          displayId: '5007',
          repeaters: [noHex, mell],
          hopBytes: 2,
          nicknames: {'': _nick('Ghost'), ...nicknames},
        ),
        'Mell',
        reason: 'the empty entry neither blocks nor steals the lookup',
      );
    });

    test('empty nicknames give null', () {
      expect(
        RepeaterNicknames.labelFor(
          displayId: '5007',
          repeaters: [mell, other],
          hopBytes: 2,
          nicknames: const {},
        ),
        isNull,
      );
    });

    test('a resolved repeater with no nickname gives null', () {
      expect(
        RepeaterNicknames.labelFor(
          displayId: '5099',
          repeaters: [mell, other],
          hopBytes: 2,
          nicknames: nicknames,
        ),
        isNull,
      );
    });
  });
}
