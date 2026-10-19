import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/user_preferences.dart';

void main() {
  test('repeater coverage lines are off by default', () {
    const prefs = UserPreferences();
    expect(prefs.showRepeaterCoverageLines, isFalse);
    expect(prefs.toJson()['showRepeaterCoverageLines'], false);
  });

  test('a missing or null value falls back to off', () {
    expect(UserPreferences.fromJson({}).showRepeaterCoverageLines, isFalse);
    expect(
        UserPreferences.fromJson({'showRepeaterCoverageLines': null})
            .showRepeaterCoverageLines,
        isFalse);
  });

  test('round trips through json', () {
    const prefs = UserPreferences(showRepeaterCoverageLines: true);
    final back = UserPreferences.fromJson(prefs.toJson());
    expect(back.showRepeaterCoverageLines, isTrue);
    expect(back, prefs);
  });

  test('copyWith changes only the field it is given', () {
    const prefs =
        UserPreferences(showRepeaterCoverageLines: true, mapStyle: 'dark');

    final off = prefs.copyWith(showRepeaterCoverageLines: false);
    expect(off.showRepeaterCoverageLines, isFalse);
    expect(off.mapStyle, 'dark');

    final style = prefs.copyWith(mapStyle: 'liberty');
    expect(style.showRepeaterCoverageLines, isTrue);

    expect(prefs.copyWith(), prefs);
  });

  test('equality and hashCode follow the field', () {
    const on = UserPreferences(showRepeaterCoverageLines: true);
    const alsoOn = UserPreferences(showRepeaterCoverageLines: true);
    const off = UserPreferences();
    expect(on, alsoOn);
    expect(on.hashCode, alsoOn.hashCode);
    expect(on, isNot(off));
    expect(on.hashCode, isNot(off.hashCode));
  });
}
