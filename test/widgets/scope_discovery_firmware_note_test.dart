import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/widgets/scope_discovery_firmware_note.dart';

const _noteText = 'Your radio needs firmware v1.16.0 or newer for this.';

void main() {
  Future<void> pump(WidgetTester tester, bool show) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ScopeDiscoveryFirmwareNote(show: show)),
        ),
      );

  testWidgets('firmware code 11 while connected shows the line',
      (tester) async {
    await pump(tester,
        scopeDiscoveryFirmwareTooOld(connected: true, firmwareCode: 11));
    expect(find.text(_noteText), findsOneWidget);
  });

  testWidgets('firmware code 13 while connected shows nothing',
      (tester) async {
    await pump(tester,
        scopeDiscoveryFirmwareTooOld(connected: true, firmwareCode: 13));
    expect(find.text(_noteText), findsNothing);
  });

  testWidgets('disconnected shows nothing', (tester) async {
    await pump(tester,
        scopeDiscoveryFirmwareTooOld(connected: false, firmwareCode: 11));
    expect(find.text(_noteText), findsNothing);
  });
}
