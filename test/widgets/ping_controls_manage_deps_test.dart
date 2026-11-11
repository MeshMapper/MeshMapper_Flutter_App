import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/widgets/ping_controls.dart';
import 'package:provider/provider.dart';

/// The Trace row's Manage button reads [AppStateProvider.isScopeRadioBusy],
/// but the row only rebuilds when its Selector record changes. Without the
/// flag in that record, Manage stayed disabled after the radio freed up
/// until some unrelated control change happened to rebuild the row.
void main() {
  testWidgets('the Trace row rebuilds when the scope radio frees up, and not '
      'on a notify that changes nothing', (tester) async {
    final state = _TraceRowState()..busy = true;
    var builds = 0;
    late bool seenBusy;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: state,
        child: Builder(builder: (context) {
          context.select<AppStateProvider, Object>(targetedDepsOf);
          builds++;
          seenBusy = context.read<AppStateProvider>().isScopeRadioBusy;
          return const SizedBox();
        }),
      ),
    );
    expect(builds, 1);
    expect(seenBusy, isTrue);

    // Unrelated notifies (GPS, noise floor, battery) must not rebuild.
    for (var i = 0; i < 10; i++) {
      state.notifyListeners();
      await tester.pump();
    }
    expect(builds, 1);

    state
      ..busy = false
      ..notifyListeners();
    await tester.pump();
    expect(builds, 2);
    expect(seenBusy, isFalse);
  });
}

class _TraceRowState extends ChangeNotifier implements AppStateProvider {
  bool busy = false;

  @override
  bool get isScopeRadioBusy => busy;
  @override
  final preferences = const UserPreferences(powerLevelSet: true);
  @override
  bool get isTargetedModeRunning => false;
  @override
  int get traceHopBytes => 1;
  @override
  String? get targetRepeaterId => null;
  @override
  bool get isConnected => true;
  @override
  bool get isAutoPingStarting => false;
  @override
  bool get isRepeaterAdminActive => false;
  @override
  bool get isPingInProgress => false;
  @override
  bool get isPingSending => false;
  @override
  bool get isAutoReconnecting => false;
  @override
  int get repeaterCount => 0;
  @override
  int? get companionFirmwareVersionCode => 9;

  // The provider's own notifyListeners is protected; the test drives it.
  @override
  // ignore: unnecessary_overrides
  void notifyListeners() => super.notifyListeners();

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.isGetter) return null;
    return super.noSuchMethod(invocation);
  }
}
