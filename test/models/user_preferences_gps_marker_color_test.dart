import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/user_preferences.dart';

void main() {
  test('the GPS marker colour is the default by default', () {
    const prefs = UserPreferences();
    expect(prefs.gpsMarkerColor, 'default');
    expect(prefs.toJson()['gpsMarkerColor'], 'default');
  });

  test('a missing, null, unknown or non-string value reads as the default',
      () {
    expect(UserPreferences.fromJson({}).gpsMarkerColor, 'default');
    for (final value in [null, 'purple', '', 3, true]) {
      expect(
          UserPreferences.fromJson({'gpsMarkerColor': value}).gpsMarkerColor,
          'default',
          reason: 'stored value $value');
    }
  });

  test('green round trips through json', () {
    const prefs = UserPreferences(gpsMarkerColor: 'green');
    final back = UserPreferences.fromJson(prefs.toJson());
    expect(back.gpsMarkerColor, 'green');
    expect(back, prefs);
  });

  test('copyWith changes only the field it is given', () {
    const prefs =
        UserPreferences(gpsMarkerColor: 'green', gpsMarkerStyle: 'car');

    final back = prefs.copyWith(gpsMarkerColor: 'default');
    expect(back.gpsMarkerColor, 'default');
    expect(back.gpsMarkerStyle, 'car');

    final style = prefs.copyWith(gpsMarkerStyle: 'bike');
    expect(style.gpsMarkerColor, 'green');

    expect(prefs.copyWith(), prefs);
  });

  test('equality and hashCode follow the field', () {
    const green = UserPreferences(gpsMarkerColor: 'green');
    const alsoGreen = UserPreferences(gpsMarkerColor: 'green');
    const plain = UserPreferences();
    expect(green, alsoGreen);
    expect(green.hashCode, alsoGreen.hashCode);
    expect(green, isNot(plain));
    expect(green.hashCode, isNot(plain.hashCode));
  });
}
