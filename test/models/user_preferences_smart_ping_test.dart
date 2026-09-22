import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/user_preferences.dart';

void main() {
  test('recent coverage filtering is opt-in and survives saving settings', () {
    expect(
        const UserPreferences().toJson()['smartPingRecentCoverageOnly'], false);
    final restored = UserPreferences.fromJson({
      'smartPingRecentCoverageOnly': true,
      'smartPingDays': 30,
    });
    expect(
        restored
            .copyWith(smartPingDays: 7)
            .toJson()['smartPingRecentCoverageOnly'],
        true);
    expect(restored, isNot(const UserPreferences(smartPingDays: 30)));
  });

  test('smart pinging defaults to on with a 14 day window', () {
    const prefs = UserPreferences();
    expect(prefs.smartPingEnabled, isTrue);
    expect(prefs.smartPingDays, 14);
    expect(SmartPingDays.min, 1);
    expect(SmartPingDays.max, 365);
    expect(SmartPingDays.defaultDays, 14);
  });

  test('round trips through json', () {
    const prefs = UserPreferences(smartPingEnabled: false, smartPingDays: 3);
    final back = UserPreferences.fromJson(prefs.toJson());
    expect(back.smartPingEnabled, isFalse);
    expect(back.smartPingDays, 3);
    expect(back, prefs);
  });

  test('any window from 1 to 365 is kept; missing or out of range falls back', () {
    expect(UserPreferences.fromJson({}).smartPingEnabled, isTrue);
    expect(UserPreferences.fromJson({}).smartPingDays, 14);
    expect(UserPreferences.fromJson({'smartPingDays': 9}).smartPingDays, 9);
    expect(UserPreferences.fromJson({'smartPingDays': 365}).smartPingDays, 365);
    expect(UserPreferences.fromJson({'smartPingDays': 0}).smartPingDays, 14);
    expect(UserPreferences.fromJson({'smartPingDays': 400}).smartPingDays, 14);
    expect(UserPreferences.fromJson({'smartPingDays': -2}).smartPingDays, 14);
  });

  test('copyWith changes only what it is given', () {
    const prefs = UserPreferences();
    final changed = prefs.copyWith(smartPingDays: 30);
    expect(changed.smartPingDays, 30);
    expect(changed.smartPingEnabled, isTrue);
    expect(prefs.copyWith(smartPingEnabled: false).smartPingEnabled, isFalse);
  });
}
