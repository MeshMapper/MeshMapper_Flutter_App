import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/screens/settings/account_overview_widgets.dart';
import 'package:mesh_mapper/services/portal_account_service.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: ListView(children: [child])));

  group('AccountOverviewCard', () {
    const overview = PortalOverview(
      points: 1234,
      weekly: 56,
      grid: 789,
      awards: [
        PortalAward(name: 'First 100', description: 'Mapped 100 grid squares'),
        PortalAward(name: 'Quiet', description: ''),
      ],
    );

    testWidgets('shows the three totals with thousands separators',
        (tester) async {
      await tester.pumpWidget(host(
          const AccountOverviewCard(overview: overview, companionCount: 3)));

      expect(find.text('1,234'), findsOneWidget);
      expect(find.text('Points'), findsOneWidget);
      expect(find.text('789'), findsOneWidget);
      expect(find.text('Grid squares'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('Companions'), findsOneWidget);
    });

    testWidgets('lists every award as a chip', (tester) async {
      await tester.pumpWidget(host(
          const AccountOverviewCard(overview: overview, companionCount: 0)));

      expect(find.text('First 100'), findsOneWidget);
      expect(find.text('Quiet'), findsOneWidget);
      expect(find.byIcon(Icons.military_tech), findsNWidgets(2));
    });

    testWidgets('tapping an award shows its description', (tester) async {
      await tester.pumpWidget(host(
          const AccountOverviewCard(overview: overview, companionCount: 0)));

      await tester.tap(find.text('First 100'));
      await tester.pumpAndSettle();

      expect(find.text('Mapped 100 grid squares'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Mapped 100 grid squares'), findsNothing);
    });

    testWidgets('an award without a description says so', (tester) async {
      await tester.pumpWidget(host(
          const AccountOverviewCard(overview: overview, companionCount: 0)));

      await tester.tap(find.text('Quiet'));
      await tester.pumpAndSettle();

      expect(find.text('No description yet.'), findsOneWidget);
    });

    testWidgets('no awards means no awards row', (tester) async {
      await tester.pumpWidget(host(const AccountOverviewCard(
        overview: PortalOverview(points: 0, weekly: 0, grid: 0, awards: []),
        companionCount: 0,
      )));

      expect(find.byIcon(Icons.military_tech), findsNothing);
      expect(find.text('0'), findsNWidgets(3));
    });
  });

  group('CompanionTile', () {
    testWidgets('prefers the name, shows the key and a points pill',
        (tester) async {
      await tester.pumpWidget(host(CompanionTile(
        companion: LinkedPubkey(
            pubkey: 'A' * 64, label: 'Stick', name: 'Spark', points: 1500),
        isConnected: false,
      )));

      expect(find.text('Spark'), findsOneWidget);
      expect(find.text('Stick'), findsNothing);
      expect(find.text('A' * 64), findsOneWidget);
      expect(find.text('1,500 pts'), findsOneWidget);
      expect(find.byIcon(Icons.memory), findsOneWidget);
    });

    testWidgets('falls back to the label, then to Companion', (tester) async {
      await tester.pumpWidget(host(Column(children: [
        CompanionTile(
          companion: LinkedPubkey(
              pubkey: 'B' * 64, label: 'Stick', name: '', points: 0),
          isConnected: false,
        ),
        CompanionTile(
          companion:
              LinkedPubkey(pubkey: 'C' * 64, label: '', name: '', points: 0),
          isConnected: false,
        ),
      ])));

      expect(find.text('Stick'), findsOneWidget);
      expect(find.text('Companion'), findsOneWidget);
    });

    testWidgets('zero points shows no pill', (tester) async {
      await tester.pumpWidget(host(CompanionTile(
        companion:
            LinkedPubkey(pubkey: 'B' * 64, label: '', name: 'X', points: 0),
        isConnected: false,
      )));

      expect(find.textContaining('pts'), findsNothing);
    });

    testWidgets('the connected radio gets the green link icon',
        (tester) async {
      await tester.pumpWidget(host(CompanionTile(
        companion:
            LinkedPubkey(pubkey: 'B' * 64, label: '', name: 'X', points: 0),
        isConnected: true,
      )));

      final icon = tester.widget<Icon>(find.byIcon(Icons.link));
      expect(icon.color, Colors.green);
      expect(find.byIcon(Icons.memory), findsNothing);
    });
  });
}
