import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/user_preferences.dart';

/// The CARpeater setting stores a full public key. The pre-share 6-hex prefix
/// is wiped on load, never carried forward, and the switch is turned off with
/// it so an unshared prefix can never be reported.
void main() {
  final key = 'AB' * 32;

  test('defaults to no key and the switch off', () {
    const prefs = UserPreferences();
    expect(prefs.carpeaterPublicKey, isNull);
    expect(prefs.ignoreCarpeater, isFalse);
  });

  test('round trips through json', () {
    final prefs =
        UserPreferences(ignoreCarpeater: true, carpeaterPublicKey: key);
    final back = UserPreferences.fromJson(prefs.toJson());
    expect(back.carpeaterPublicKey, key);
    expect(back.ignoreCarpeater, isTrue);
    expect(back, prefs);
  });

  test('a stored value that is not a full key loads as null', () {
    expect(UserPreferences.fromJson({'carpeaterPublicKey': '4E12AB'})
        .carpeaterPublicKey, isNull);
    expect(UserPreferences.fromJson({'carpeaterPublicKey': key.toLowerCase()})
        .carpeaterPublicKey, key);
  });

  test('copyWith can clear the key', () {
    final prefs =
        UserPreferences(ignoreCarpeater: true, carpeaterPublicKey: key);
    expect(prefs.copyWith(carpeaterPublicKey: null).carpeaterPublicKey, key);
    expect(prefs.copyWith(clearCarpeaterPublicKey: true).carpeaterPublicKey,
        isNull);
  });

  group('stripLegacyCarpeater', () {
    test('wipes a legacy prefix and turns the switch off', () {
      final result = UserPreferences.stripLegacyCarpeater({
        'ignoreCarpeater': true,
        'ignoreRepeaterId': '4E12AB',
        'autoPingInterval': 15,
      });
      expect(result.wiped, isTrue);
      expect(result.json.containsKey('ignoreRepeaterId'), isFalse);
      expect(result.json['ignoreCarpeater'], isFalse);
      expect(result.json['autoPingInterval'], 15);
      final prefs = UserPreferences.fromJson(result.json);
      expect(prefs.carpeaterPublicKey, isNull);
      expect(prefs.ignoreCarpeater, isFalse);
    });

    test('a null legacy value is removed without counting as a wipe', () {
      final result = UserPreferences.stripLegacyCarpeater({
        'ignoreCarpeater': false,
        'ignoreRepeaterId': null,
      });
      expect(result.wiped, isFalse);
      expect(result.json.containsKey('ignoreRepeaterId'), isFalse);
      expect(result.json['ignoreCarpeater'], isFalse);
    });

    test('a map in the new shape is returned as is', () {
      final json = {'ignoreCarpeater': true, 'carpeaterPublicKey': key};
      final result = UserPreferences.stripLegacyCarpeater(json);
      expect(result.wiped, isFalse);
      expect(result.json, same(json));
    });
  });
}
