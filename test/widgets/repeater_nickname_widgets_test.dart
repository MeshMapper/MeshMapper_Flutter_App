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

  testWidgets('a display tag shows the nickname', (tester) async {
    await tester.pumpWidget(host(const RepeaterNicknameTag(nickname: 'Mell')));
    expect(find.text('Mell'), findsOneWidget);
  });

  testWidgets('the button reads Nickname until one is set, then the nickname',
      (tester) async {
    var presses = 0;
    await tester.pumpWidget(host(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepeaterNicknameButton(nickname: null, onPressed: () => presses++),
        RepeaterNicknameButton(nickname: 'Mell', onPressed: () => presses++),
      ],
    )));

    expect(find.byIcon(Icons.add), findsOneWidget);
    expect(find.byIcon(Icons.label_outline), findsOneWidget);
    await tester.tap(find.text('Nickname'));
    await tester.tap(find.text('Mell'));
    expect(presses, 2);
  });

  testWidgets('the button reads as one named button', (tester) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(host(Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        RepeaterNicknameButton(nickname: null, onPressed: () {}),
        RepeaterNicknameButton(nickname: 'Mell', onPressed: () {}),
      ],
    )));

    for (final label in ['Add nickname', 'Edit nickname Mell']) {
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        matchesSemantics(
          label: label,
          isButton: true,
          hasTapAction: true,
        ),
      );
    }
    semantics.dispose();
  });

  testWidgets('the hex badge shows the hex', (tester) async {
    await tester.pumpWidget(host(const RepeaterHexBadge('5007')));
    expect(find.text('5007'), findsOneWidget);
  });
}
