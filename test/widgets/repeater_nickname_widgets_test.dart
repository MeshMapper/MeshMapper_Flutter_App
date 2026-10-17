import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/widgets/repeater_nickname_widgets.dart';

void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  testWidgets('a display tag with no nickname draws nothing', (tester) async {
    await tester.pumpWidget(host(const RepeaterNicknameTag(nickname: null)));

    expect(find.byType(Text), findsNothing);
    expect(tester.getSize(find.byType(RepeaterNicknameTag)), Size.zero);
  });

  testWidgets('the editable tag is at least 40 tall, set or not',
      (tester) async {
    var taps = 0;
    await tester.pumpWidget(host(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepeaterNicknameTag(nickname: null, onTap: () => taps++),
        RepeaterNicknameTag(nickname: 'Mell', onTap: () => taps++),
      ],
    )));

    final add = tester.getSize(find.byType(RepeaterNicknameTag).first);
    final set = tester.getSize(find.byType(RepeaterNicknameTag).last);
    expect(add.height, greaterThanOrEqualTo(40));
    // Same height either way, so the sheet does not move when one is set.
    expect(set.height, add.height);

    await tester.tap(find.text('Add nickname'));
    await tester.tap(find.text('Mell'));
    expect(taps, 2);
    expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
  });

  testWidgets('the hex badge shows the hex', (tester) async {
    await tester.pumpWidget(host(const RepeaterHexBadge('5007')));
    expect(find.text('5007'), findsOneWidget);
  });
}
