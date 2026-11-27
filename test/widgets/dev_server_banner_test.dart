import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/screens/settings/server_settings_card.dart';

void main() {
  Future<void> pump(WidgetTester tester, {double width = 390}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          DevServerBanner(serverName: 'dev.meshmapper.net'),
        ]),
      ),
    ));
  }

  testWidgets('names the server', (tester) async {
    await pump(tester);
    expect(find.textContaining('DEV SERVER'), findsOneWidget);
    expect(find.textContaining('dev.meshmapper.net'), findsOneWidget);
  });

  testWidgets('spans the full width so it cannot be missed', (tester) async {
    await pump(tester);
    expect(tester.getSize(find.byType(DevServerBanner)).width, 390);
  });

  testWidgets('cannot be dismissed: nothing in it responds to a tap, a swipe '
      'or a long press', (tester) async {
    await pump(tester);
    final banner = find.byType(DevServerBanner);
    for (final type in [
      GestureDetector,
      InkWell,
      IconButton,
      TextButton,
      Dismissible,
    ]) {
      expect(find.descendant(of: banner, matching: find.byType(type)),
          findsNothing,
          reason: '$type');
    }
    await tester.tap(banner);
    await tester.longPress(banner);
    await tester.drag(banner, const Offset(400, 0));
    await tester.drag(banner, const Offset(0, -200));
    await tester.pumpAndSettle();
    expect(find.textContaining('dev.meshmapper.net'), findsOneWidget);
  });

  testWidgets('a long server name does not overflow a narrow screen',
      (tester) async {
    tester.view.physicalSize = const Size(280, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Column(children: [
          DevServerBanner(
              serverName: 'a-very-long-test-server-name.dev.meshmapper.net'),
        ]),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
