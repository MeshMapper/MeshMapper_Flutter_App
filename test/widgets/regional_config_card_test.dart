import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/widgets/regional_config_card.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('a grouped zone shows the full group code and the member',
      (tester) async {
    await tester.pumpWidget(_wrap(const RegionalConfigCard(
        zoneName: 'Ottawa',
        zoneCode: 'YOW',
        groupCode: 'FINLAND',
        compact: true)));
    expect(find.text('Region'), findsOneWidget);
    expect(find.text('FINLAND'), findsOneWidget);
    expect(find.text('YOW'), findsOneWidget);
  });

  testWidgets('no group shows no Region row', (tester) async {
    await tester.pumpWidget(_wrap(const RegionalConfigCard(
        zoneName: 'Ottawa', zoneCode: 'YOW', compact: true)));
    expect(find.text('Region'), findsNothing);
  });

  testWidgets('offline hides the Region row', (tester) async {
    await tester.pumpWidget(_wrap(const RegionalConfigCard(
        zoneCode: 'YOW',
        groupCode: 'ONQC',
        isOfflineMode: true,
        compact: true)));
    expect(find.text('Region'), findsNothing);
  });
}
