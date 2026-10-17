import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/widgets/repeater_nickname_dialog.dart';

/// What the dialog handed back, once it has closed.
class _Outcome {
  bool closed = false;
  String? result;
}

void main() {
  /// Opens the dialog over a throwaway page.
  Future<_Outcome> openDialog(WidgetTester tester, {String? current}) async {
    final outcome = _Outcome();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              outcome.result = await showRepeaterNicknameDialog(
                context,
                hex: '5007',
                serverName: 'Mellionnec Repeater',
                current: current,
              );
              outcome.closed = true;
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return outcome;
  }

  testWidgets('shows the hex, the server name and the helper', (tester) async {
    await openDialog(tester);

    expect(find.text('Repeater nickname'), findsOneWidget);
    expect(find.text('5007'), findsOneWidget);
    expect(find.text('Mellionnec Repeater'), findsOneWidget);
    expect(
      find.text('Shows instead of 5007 in Top Heard, on the Live Activity, '
          'CarPlay, Apple Watch and Siri. If another repeater shares 5007, '
          'the ID shows instead.'),
      findsOneWidget,
    );
  });

  testWidgets('saving a long name returns it capped at 8', (tester) async {
    final outcome = await openDialog(tester);

    await tester.enterText(find.byType(TextField), 'Mellionnec');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(outcome.closed, isTrue);
    expect(outcome.result, 'Mellionn');
  });

  testWidgets('submitting the field saves', (tester) async {
    final outcome = await openDialog(tester);

    await tester.enterText(find.byType(TextField), '  Goar  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(outcome.result, 'Goar');
  });

  testWidgets('cancel returns null', (tester) async {
    final outcome = await openDialog(tester, current: 'Mell');

    await tester.enterText(find.byType(TextField), 'Other');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(outcome.closed, isTrue);
    expect(outcome.result, isNull);
  });

  testWidgets('Remove is offered only for a current nickname', (tester) async {
    await openDialog(tester);
    expect(find.text('Remove'), findsNothing);
  });

  testWidgets('Remove returns an empty string', (tester) async {
    final outcome = await openDialog(tester, current: 'Mell');

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.controller!.text, 'Mell');
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();

    expect(outcome.closed, isTrue);
    expect(outcome.result, '');
  });

  testWidgets('a blank save returns an empty string', (tester) async {
    final outcome = await openDialog(tester, current: 'Mell');

    await tester.enterText(find.byType(TextField), '   ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(outcome.result, '');
  });

  group('nicknameResultChanges', () {
    test('a cancel changes nothing', () {
      expect(nicknameResultChanges(null, null), isFalse);
      expect(nicknameResultChanges(null, 'Mell'), isFalse);
    });

    test('the same nickname again changes nothing', () {
      expect(nicknameResultChanges('Mell', 'Mell'), isFalse);
    });

    test('removing a nickname that is not there changes nothing', () {
      expect(nicknameResultChanges('', null), isFalse);
    });

    test('a new, different or removed nickname is a change', () {
      expect(nicknameResultChanges('Mell', null), isTrue);
      expect(nicknameResultChanges('Goar', 'Mell'), isTrue);
      expect(nicknameResultChanges('', 'Mell'), isTrue);
    });
  });
}
