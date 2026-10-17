import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/screens/settings/repeater_nicknames_page.dart';
import 'package:mesh_mapper/utils/repeater_nicknames.dart';

final String _mellKey = '5007${'A' * 60}';
final String _goarKey = '40E6${'B' * 60}';

const _mell = RepeaterNickname(
  nickname: 'Mell',
  name: 'Mellionnec Repeater',
  hex: '5007',
);
const _goar = RepeaterNickname(nickname: 'Goar', name: '', hex: '40E6');

void main() {
  final edits = <(String, RepeaterNickname)>[];
  final removals = <(String, RepeaterNickname)>[];
  var adds = 0;

  setUp(() {
    edits.clear();
    removals.clear();
    adds = 0;
  });

  Widget host(List<MapEntry<String, RepeaterNickname>> entries) => MaterialApp(
        home: Scaffold(
          body: RepeaterNicknameList(
            entries: entries,
            onEdit: (key, entry) => edits.add((key, entry)),
            onRemove: (key, entry) => removals.add((key, entry)),
            onAdd: () => adds++,
          ),
        ),
      );

  testWidgets('the empty state explains and offers Add', (tester) async {
    await tester.pumpWidget(host(const []));

    expect(
      find.text('Give repeaters your own short names, like Mell for 5007. '
          'They show instead of the ID in Top Heard, and as the name on the '
          'Live Activity, CarPlay, Apple Watch and Siri.'),
      findsOneWidget,
    );
    expect(
        find.text('You can also tap a repeater on the map.'), findsOneWidget);

    await tester.tap(find.text('Add nickname'));
    expect(adds, 1);
  });

  testWidgets('each entry shows its hex, nickname and server name',
      (tester) async {
    await tester.pumpWidget(host([MapEntry(_mellKey, _mell)]));

    expect(find.text('Nicknames'), findsOneWidget);
    expect(find.text('5007'), findsOneWidget);
    expect(find.text('Mell'), findsOneWidget);
    expect(find.text('Mellionnec Repeater'), findsOneWidget);
    expect(find.text('Add nickname'), findsNothing);
  });

  testWidgets('an entry with no server name has no subtitle', (tester) async {
    await tester.pumpWidget(host([MapEntry(_goarKey, _goar)]));

    final tile = tester.widget<ListTile>(find.byType(ListTile));
    expect(tile.subtitle, isNull);
  });

  testWidgets('delete removes that entry by key', (tester) async {
    await tester.pumpWidget(host([
      MapEntry(_mellKey, _mell),
      MapEntry(_goarKey, _goar),
    ]));

    await tester.tap(find.byTooltip('Remove').last);

    expect(removals, [(_goarKey, _goar)]);
    expect(edits, isEmpty);
  });

  testWidgets('tapping an entry edits it', (tester) async {
    await tester.pumpWidget(host([
      MapEntry(_mellKey, _mell),
      MapEntry(_goarKey, _goar),
    ]));

    await tester.tap(find.text('Mell'));

    expect(edits, [(_mellKey, _mell)]);
    expect(removals, isEmpty);
  });
}
