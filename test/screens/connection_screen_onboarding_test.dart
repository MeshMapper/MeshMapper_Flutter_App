import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/screens/connection_screen.dart';
import 'package:mesh_mapper/screens/onboarding/onboarding_prompt_gate.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final automatic in [false, true]) {
    testWidgets('connection warning waits for onboarding automatic=$automatic',
        (tester) async {
      final appState = _ConnectedAppState();
      addTearDown(appState.dispose);
      await tester.pumpWidget(_host(appState, automatic: automatic));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open onboarding'));
      await tester.pumpAndSettle();

      appState.queuePathWarning();
      await tester.pumpAndSettle();
      expect(find.text('Multi-Byte Paths Enabled'), findsNothing);
      expect(appState.pendingPathHashWarning, isNotNull);
      // Repeated provider notifications must not schedule warnings while held.
      appState.queuePathWarning();
      await tester.pumpAndSettle();
      expect(find.text('Multi-Byte Paths Enabled'), findsNothing);

      if (automatic) {
        await tester.tap(find.text('Start Guide'));
        await tester.pumpAndSettle();
        expect(find.text('Multi-Byte Paths Enabled'), findsNothing);
        expect(appState.pendingPathHashWarning, isNotNull);
      }
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Multi-Byte Paths Enabled'), findsOneWidget);
      expect(appState.pendingPathHashWarning, isNull);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(find.text('Multi-Byte Paths Enabled'), findsNothing);
      expect(find.byType(ConnectionScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('connection disposes safely while onboarding holds a warning',
      (tester) async {
    final appState = _ConnectedAppState();
    final connectionVisible = ValueNotifier(true);
    addTearDown(appState.dispose);
    addTearDown(connectionVisible.dispose);
    await tester
        .pumpWidget(_host(appState, connectionVisible: connectionVisible));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open onboarding'));
    await tester.pumpAndSettle();
    appState.queuePathWarning();
    await tester.pumpAndSettle();
    expect(appState.pendingPathHashWarning, isNotNull);
    connectionVisible.value = false;
    await tester.pump();
    expect(find.byType(ConnectionScreen, skipOffstage: false), findsNothing);
    // Verify listener ownership without adding a test-only production API.
    // ignore: invalid_use_of_protected_member
    expect(OnboardingGuideCoordinator.shared.hasListeners, isFalse);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(OnboardingGuideCoordinator.shared.isReserved, isFalse);
    expect(appState.pendingPathHashWarning, isNotNull);
    expect(find.text('Multi-Byte Paths Enabled'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('scheduled connection warning rechecks onboarding reservation',
      (tester) async {
    final appState = _ConnectedAppState()..queuePathWarning();
    addTearDown(appState.dispose);
    final presenter = OnboardingGuidePresenter();
    var guideScheduled = false;
    await tester.pumpWidget(ChangeNotifierProvider<AppStateProvider>.value(
      value: appState,
      child: MaterialApp(
        home: Builder(builder: (context) {
          if (!guideScheduled) {
            guideScheduled = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              presenter.showManual(context);
            });
          }
          return const ConnectionScreen();
        }),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Page 1 of 12'), findsOneWidget);
    expect(find.text('Multi-Byte Paths Enabled'), findsNothing);
    expect(appState.pendingPathHashWarning, isNotNull);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Multi-Byte Paths Enabled'), findsOneWidget);
    expect(appState.pendingPathHashWarning, isNull);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.text('Multi-Byte Paths Enabled'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Widget _host(_ConnectedAppState appState,
    {bool automatic = false, ValueNotifier<bool>? connectionVisible}) {
  final presenter = OnboardingGuidePresenter();
  return ChangeNotifierProvider<AppStateProvider>.value(
    value: appState,
    child: MaterialApp(
      home: Builder(
        builder: (context) => Column(
          children: [
            Expanded(
              child: connectionVisible == null
                  ? const ConnectionScreen()
                  : ValueListenableBuilder<bool>(
                      valueListenable: connectionVisible,
                      builder: (_, visible, __) =>
                          visible ? const ConnectionScreen() : const SizedBox(),
                    ),
            ),
            TextButton(
              onPressed: () => automatic
                  ? presenter.showAutomatic(context,
                      complete: () async => true, returnToMap: () {})
                  : presenter.showManual(context),
              child: const Text('Open onboarding'),
            ),
          ],
        ),
      ),
    ),
  );
}

// Supply a connected snapshot without starting BLE, GPS or API services.
// The actual screen owns all warning scheduling and dialog presentation.
class _ConnectedAppState extends ChangeNotifier implements AppStateProvider {
  @override
  final preferences = const UserPreferences(powerLevelSet: true);
  @override
  ConnectionStep get connectionStep => ConnectionStep.connected;
  @override
  bool get isConnected => true;
  @override
  bool get isZoneTransferInProgress => false;
  @override
  bool get isInZoneGracePeriod => false;
  @override
  bool get isAirborne => false;
  @override
  bool get offlineMode => false;
  @override
  bool get maintenanceMode => false;
  @override
  bool get isCheckingZone => false;
  @override
  bool get floodDisabled => false;
  @override
  bool get autoPingEnabled => false;
  @override
  List<String> get regionalChannels => [];

  ({int hopBytes, String reason})? _warning;
  @override
  ({int hopBytes, String reason})? get pendingPathHashWarning => _warning;

  void queuePathWarning() {
    _warning = (hopBytes: 2, reason: 'set by your regional admin');
    notifyListeners();
  }

  @override
  void clearPathHashWarning() {
    _warning = null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) return null;
    return super.noSuchMethod(invocation);
  }
}
