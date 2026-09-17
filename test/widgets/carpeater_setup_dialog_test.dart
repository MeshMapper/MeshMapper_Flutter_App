import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/widgets/carpeater_setup_dialog.dart';

/// The CARpeater setup dialog answers the re-entry prompt both ways: a full
/// key set by hand, and an empty field saved on purpose. Clearing the field is
/// the user saying they have no CARpeater, so it has to take the same provider
/// path as the prompt's own "I don't use a CARpeater" button. It did not, and
/// because the provider only dismisses the prompt when a key is SET, the
/// "filter reset" dialog came back after every connect.
///
/// The dialog reads four things from the provider, so it is stood up here on a
/// stand-in rather than a real [AppStateProvider]: building one starts the
/// whole app (GPS, audio, portal, Hive), none of which this dialog touches.
class _FakeAppState implements AppStateProvider {
  _FakeAppState({UserPreferences? preferences})
      : _preferences = preferences ?? const UserPreferences();

  UserPreferences _preferences;
  int dismissCalls = 0;

  @override
  UserPreferences get preferences => _preferences;

  @override
  bool get autoPingEnabled => false;

  @override
  List<Repeater> get repeaters => const [];

  @override
  void updatePreferences(UserPreferences preferences) {
    _preferences = preferences;
  }

  @override
  Future<void> dismissCarpeaterReentry() async {
    dismissCalls++;
  }

  /// Anything else is outside what this dialog is allowed to reach for.
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('the dialog reached for ${invocation.memberName}');
}

void main() {
  /// Opens the dialog over a throwaway page and returns the fake it runs on.
  Future<_FakeAppState> openDialog(
    WidgetTester tester, {
    UserPreferences? preferences,
  }) async {
    final appState = _FakeAppState(preferences: preferences);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showCarpeaterSetupDialog(context, appState),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('My CARpeater'), findsOneWidget);
    return appState;
  }

  testWidgets('saving an empty key clears it and dismisses the prompt',
      (tester) async {
    final appState = await openDialog(tester,
        preferences: UserPreferences(
          carpeaterPublicKey: 'AB' * 32,
          ignoreCarpeater: true,
        ));

    await tester.enterText(find.byType(TextField), '');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(appState.preferences.carpeaterPublicKey, isNull);
    expect(appState.preferences.ignoreCarpeater, isFalse);
    expect(appState.dismissCalls, 1,
        reason: 'clearing the field is the user saying they have no '
            'CARpeater, so the prompt must not come back after every connect');
    expect(find.text('My CARpeater'), findsNothing);
  });

  testWidgets('saving a full key stores it and turns the filter on',
      (tester) async {
    final appState = await openDialog(tester);
    final key = 'CD' * 32;

    await tester.enterText(find.byType(TextField), key);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(appState.preferences.carpeaterPublicKey, key);
    expect(appState.preferences.ignoreCarpeater, isTrue);
    // This path needs no call of its own: the real provider dismisses the
    // prompt from inside updatePreferences whenever a key is set. That is
    // exactly the asymmetry the cleared case fell through.
    expect(appState.dismissCalls, 0);
    expect(find.text('My CARpeater'), findsNothing);
  });

  testWidgets('a half-typed key saves nothing and keeps the dialog open',
      (tester) async {
    final appState = await openDialog(tester);

    await tester.enterText(find.byType(TextField), 'ABCD');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(appState.preferences.carpeaterPublicKey, isNull);
    expect(appState.dismissCalls, 0,
        reason: 'a rejected key is not an answer to the prompt');
    expect(find.text('My CARpeater'), findsOneWidget);
  });

  testWidgets('Cancel changes nothing', (tester) async {
    final appState = await openDialog(tester);

    await tester.enterText(find.byType(TextField), 'EF' * 32);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(appState.preferences.carpeaterPublicKey, isNull);
    expect(appState.dismissCalls, 0);
    expect(find.text('My CARpeater'), findsNothing);
  });
}
