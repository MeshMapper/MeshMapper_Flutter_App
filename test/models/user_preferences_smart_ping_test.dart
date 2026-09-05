import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/user_preferences.dart';

void main() {
  test('smart pinging defaults to on with a 14 day window', () {
    const prefs = UserPreferences();
    expect(prefs.smartPingEnabled, isTrue);
    expect(prefs.smartPingDays, 14);
    expect(SmartPingDays.values, [1, 3, 7, 14, 30]);
    expect(SmartPingDays.defaultDays, 14);
  });

  test('round trips through json', () {
    const prefs = UserPreferences(smartPingEnabled: false, smartPingDays: 3);
    final back = UserPreferences.fromJson(prefs.toJson());
    expect(back.smartPingEnabled, isFalse);
    expect(back.smartPingDays, 3);
    expect(back, prefs);
  });

  test('missing or invalid json falls back to the defaults', () {
    expect(UserPreferences.fromJson({}).smartPingEnabled, isTrue);
    expect(UserPreferences.fromJson({}).smartPingDays, 14);
    expect(UserPreferences.fromJson({'smartPingDays': 9}).smartPingDays, 14);
    expect(UserPreferences.fromJson({'smartPingDays': 0}).smartPingDays, 14);
  });

  test('copyWith changes only what it is given', () {
    const prefs = UserPreferences();
    final changed = prefs.copyWith(smartPingDays: 30);
    expect(changed.smartPingDays, 30);
    expect(changed.smartPingEnabled, isTrue);
    expect(prefs.copyWith(smartPingEnabled: false).smartPingEnabled, isFalse);
  });
}
