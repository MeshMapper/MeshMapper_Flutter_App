import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/user_preferences.dart';

void main() {
  test('the row range is 3 to 8, defaulting to 3', () {
    expect(UserPreferences.topHeardRowsMin, 3);
    expect(UserPreferences.topHeardRowsMax, 8);
    expect(UserPreferences.topHeardRowsDefault, 3);
  });

  test('Top Heard shows 3 rows with hex IDs by default', () {
    const prefs = UserPreferences();
    expect(prefs.topHeardRows, 3);
    expect(prefs.topHeardShowNames, isFalse);
    expect(prefs.toJson()['topHeardRows'], 3);
    expect(prefs.toJson()['topHeardShowNames'], false);
  });

  test('round trips non-default values through json', () {
    const prefs = UserPreferences(topHeardRows: 6, topHeardShowNames: true);
    final back = UserPreferences.fromJson(prefs.toJson());
    expect(back.topHeardRows, 6);
    expect(back.topHeardShowNames, isTrue);
    expect(back, prefs);
  });

  test('copyWith changes only the field it is given', () {
    const prefs = UserPreferences(topHeardRows: 5, topHeardShowNames: true);

    final rows = prefs.copyWith(topHeardRows: 8);
    expect(rows.topHeardRows, 8);
    expect(rows.topHeardShowNames, isTrue);

    final names = prefs.copyWith(topHeardShowNames: false);
    expect(names.topHeardShowNames, isFalse);
    expect(names.topHeardRows, 5);

    expect(prefs.copyWith(), prefs);
  });

  test('missing keys fall back to the defaults', () {
    final prefs = UserPreferences.fromJson({});
    expect(prefs.topHeardRows, 3);
    expect(prefs.topHeardShowNames, isFalse);
  });

  test('the row count is clamped to 3..8', () {
    int rows(Object? value) =>
        UserPreferences.fromJson({'topHeardRows': value}).topHeardRows;

    expect(rows(3), 3);
    expect(rows(8), 8);
    expect(rows(5), 5);
    expect(rows(0), 3);
    expect(rows(-4), 3);
    expect(rows(2), 3);
    expect(rows(9), 8);
    expect(rows(99), 8);
  });

  test('a numeric row count is truncated, anything else is the default', () {
    int rows(Object? value) =>
        UserPreferences.fromJson({'topHeardRows': value}).topHeardRows;

    expect(rows(5.0), 5);
    expect(rows(5.9), 5);
    expect(rows(double.nan), 3);
    expect(rows(double.infinity), 3);
    expect(rows('6'), 3);
    expect(rows(null), 3);
    expect(rows(true), 3);
    expect(rows(const [6]), 3);
  });

  test('equality and hashCode follow both fields', () {
    const base = UserPreferences(topHeardRows: 5, topHeardShowNames: true);
    const same = UserPreferences(topHeardRows: 5, topHeardShowNames: true);
    const otherRows = UserPreferences(topHeardRows: 6, topHeardShowNames: true);
    const otherNames =
        UserPreferences(topHeardRows: 5, topHeardShowNames: false);

    expect(base, same);
    expect(base.hashCode, same.hashCode);
    expect(base, isNot(otherRows));
    expect(base.hashCode, isNot(otherRows.hashCode));
    expect(base, isNot(otherNames));
    expect(base.hashCode, isNot(otherNames.hashCode));
  });
}
