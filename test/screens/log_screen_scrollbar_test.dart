import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/log_entry.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';
import 'package:mesh_mapper/screens/log_screen.dart';

/// A long ping log had no scrollbar, so there was no telling how far down it
/// you were (#616). Phones draw none unless the list asks for one. The list
/// keeps its own scroll controller: on iOS and Android a list without one
/// inherits the screen's primary controller, and the two log tabs share one
/// TabBarView, so a Scrollbar on the inherited controller would see two lists.
/// Scope entries only, as in log_screen_scopes_test.dart: their cards need no
/// AppStateProvider to build.
void main() {
  List<UnifiedPingLogEntry> entries(int count) => [
        for (var i = 0; i < count; i++)
          () {
            final entry = ScopeLogEntry(
              timestamp: DateTime(2026, 9, 26, 9, 0, i),
              latitude: 45.1,
              longitude: -75.2,
              repeaterId: 'AB',
              pubkeyHex: 'AB' * 32,
              outcome: ScopeLogOutcome.answered,
              scopes: const ['Ottawa'],
            );
            return UnifiedPingLogEntry(
                type: PingLogType.scopes,
                timestamp: entry.timestamp,
                entry: entry);
          }(),
      ];

  testWidgets('the ping list has a draggable scrollbar on phones',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AllPingsTab(
          allEntries: entries(60),
          repeaters: const [],
          txCount: 0,
          rxCount: 0,
          discCount: 0,
          traceCount: 0,
          scopeCount: 60,
        ),
      ),
    ));

    final scrollbar = find.byType(Scrollbar);
    expect(scrollbar, findsOneWidget);
    final widget = tester.widget<Scrollbar>(scrollbar);
    expect(widget.controller, isNotNull,
        reason: 'its own controller, never the inherited primary one');
    expect(widget.interactive, isTrue);

    await tester.drag(find.byType(ListView), const Offset(0, -600));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(widget.controller!.offset, greaterThan(0));
  },
      variant: const TargetPlatformVariant(
          {TargetPlatform.iOS, TargetPlatform.android}));
}
