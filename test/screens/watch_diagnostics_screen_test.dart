import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/screens/watch_diagnostics_screen.dart';
import 'package:mesh_mapper/services/watch/watch_bridge_service.dart';

/// Renders the diagnostic in the exact shape of the 2026-08-14 incident:
/// paired and reachable, but `installed` false, which silently closed the
/// sync gate for two hours with no log line anywhere.
void main() {
  testWidgets('names the condition that closed the gate', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    const channel = MethodChannel('meshmapper/watch_diag_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'status') {
        return {
          'supported': true,
          'activated': true,
          'paired': true,
          'installed': false,
          'reachable': true,
        };
      }
      return null;
    });
    final bridge = WatchBridgeService(channel: channel);

    await tester.pumpWidget(
      MaterialApp(home: WatchDiagnosticsScreen(bridge: bridge)),
    );
    await tester.pump();

    expect(find.text('Failing condition: installed'), findsOneWidget);
    expect(find.text('installed'), findsOneWidget);
    expect(find.text('canSync'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    bridge.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
}
