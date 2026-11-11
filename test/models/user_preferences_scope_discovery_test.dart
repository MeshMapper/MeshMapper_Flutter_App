import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/user_preferences.dart';

void main() {
  test('scope discovery defaults to off with a 14 day window', () {
    const prefs = UserPreferences();
    expect(prefs.scopeDiscoveryEnabled, isFalse);
    expect(prefs.scopeDiscoveryDays, 14);
    expect(ScopeDiscoveryDays.min, 7);
    expect(ScopeDiscoveryDays.max, 365);
    expect(ScopeDiscoveryDays.defaultDays, 14);
  });

  test('round trips through json', () {
    const prefs =
        UserPreferences(scopeDiscoveryEnabled: true, scopeDiscoveryDays: 30);
    final back = UserPreferences.fromJson(prefs.toJson());
    expect(back.scopeDiscoveryEnabled, isTrue);
    expect(back.scopeDiscoveryDays, 30);
    expect(back, prefs);
  });

  test('stored 3 reads 7, stored 400 reads 365, missing reads 14', () {
    expect(
        UserPreferences.fromJson({'scopeDiscoveryDays': 3}).scopeDiscoveryDays,
        7);
    expect(
        UserPreferences.fromJson({'scopeDiscoveryDays': 400})
            .scopeDiscoveryDays,
        365);
    expect(UserPreferences.fromJson({}).scopeDiscoveryDays, 14);
    expect(UserPreferences.fromJson({}).scopeDiscoveryEnabled, isFalse);
  });

  test('copyWith changes only what it is given', () {
    const prefs = UserPreferences();
    final changed = prefs.copyWith(scopeDiscoveryDays: 30);
    expect(changed.scopeDiscoveryDays, 30);
    expect(changed.scopeDiscoveryEnabled, isFalse);
    expect(
        prefs.copyWith(scopeDiscoveryEnabled: true).scopeDiscoveryEnabled,
        isTrue);
  });

  test('equality includes both fields', () {
    const base = UserPreferences();
    expect(base, const UserPreferences());
    expect(base, isNot(const UserPreferences(scopeDiscoveryEnabled: true)));
    expect(base, isNot(const UserPreferences(scopeDiscoveryDays: 30)));
  });
}
