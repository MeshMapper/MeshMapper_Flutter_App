import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/log_entry.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';
import 'package:mesh_mapper/screens/log_screen.dart';
import 'package:mesh_mapper/utils/ping_colors.dart';

/// `AppStateProvider` (constructed by `LogScreen`, which owns the private
/// `_AllPingsTab`/`_AllPingsTabState`) cannot be built in this suite: its
/// constructor opens Hive boxes and starts BLE/GPS (see
/// `test/widgets/ping_controls_scope_badge_test.dart`, which hit the same
/// wall for the Task 7 badge). `AllPingsTab` is the public widget that
/// `_AllPingsTab` was renamed to precisely so a test can pump the real filter
/// row, search field and card list directly, without going through
/// `LogScreen`. It needs no Provider ancestor either, as long as the fixture
/// entries are all `ScopeLogEntry` (the only per-type card builder whose
/// `AppStateProvider` read is deferred to its card's own tap, never the
/// build) and nothing taps a card body. `LogFilterSegment` and `ScopeLogCard`
/// are additionally pumped standalone below for the narrower, presentational
/// assertions (colour, "99+" cap, exact scope-name text) that do not need the
/// surrounding tab at all.
ScopeLogEntry _entry({
  DateTime? timestamp,
  String repeaterId = 'AB',
  ScopeLogOutcome outcome = ScopeLogOutcome.answered,
  List<String>? scopes,
}) {
  return ScopeLogEntry(
    timestamp: timestamp ?? DateTime(2026, 9, 26, 9, 4, 7),
    latitude: 45.1,
    longitude: -75.2,
    repeaterId: repeaterId,
    pubkeyHex: repeaterId * 32,
    outcome: outcome,
    scopes: scopes,
  );
}

UnifiedPingLogEntry _scopeUnified(ScopeLogEntry entry) => UnifiedPingLogEntry(
    type: PingLogType.scopes, timestamp: entry.timestamp, entry: entry);

void main() {
  group('AllPingsTab (real wiring)', () {
    testWidgets(
        'tapping SCP hides the rendered scope cards, tapping again shows them',
        (tester) async {
      final ottawa = _entry(repeaterId: 'AB', scopes: const ['Ottawa']);
      final west = _entry(
          repeaterId: 'CD',
          timestamp: DateTime(2026, 9, 26, 9, 5),
          scopes: const ['west']);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AllPingsTab(
            allEntries: [_scopeUnified(ottawa), _scopeUnified(west)],
            repeaters: const [],
            txCount: 0,
            rxCount: 0,
            discCount: 0,
            traceCount: 0,
            scopeCount: 2,
          ),
        ),
      ));

      expect(find.byType(ScopeLogCard), findsNWidgets(2));

      final scpSegment = find.descendant(
          of: find.byType(LogFilterSegment), matching: find.text('SCP'));
      expect(scpSegment, findsOneWidget);

      await tester.tap(scpSegment);
      await tester.pump();
      expect(find.byType(ScopeLogCard), findsNothing);

      await tester.tap(scpSegment);
      await tester.pump();
      expect(find.byType(ScopeLogCard), findsNWidgets(2));
    });

    testWidgets(
        'typing a scope name into the search field shows only that card',
        (tester) async {
      final ottawa = _entry(repeaterId: 'AB', scopes: const ['Ottawa']);
      final west = _entry(
          repeaterId: 'CD',
          timestamp: DateTime(2026, 9, 26, 9, 5),
          scopes: const ['west']);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: AllPingsTab(
            allEntries: [_scopeUnified(ottawa), _scopeUnified(west)],
            repeaters: const [],
            txCount: 0,
            rxCount: 0,
            discCount: 0,
            traceCount: 0,
            scopeCount: 2,
          ),
        ),
      ));

      expect(find.byType(ScopeLogCard), findsNWidgets(2));

      await tester.enterText(find.byType(TextField), 'Ottawa');
      await tester.pump();

      expect(find.byType(ScopeLogCard), findsOneWidget);
      expect(find.text('AB'), findsOneWidget);
      expect(find.text('CD'), findsNothing);

      // Scope names are case-sensitive: the lowercase form matches neither
      // card.
      await tester.enterText(find.byType(TextField), 'ottawa');
      await tester.pump();

      expect(find.byType(ScopeLogCard), findsNothing);
    });
  });

  group('LogFilterSegment (SCP)', () {
    testWidgets('renders the SCP label and a count pill', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              LogFilterSegment(
                type: PingLogType.scopes,
                label: 'SCP',
                count: 12,
                color: PingColors.scopes,
                active: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ));

      expect(find.text('SCP'), findsOneWidget);
      expect(find.text('12'), findsOneWidget);
    });

    testWidgets('tapping calls onTap', (tester) async {
      var tapped = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              LogFilterSegment(
                type: PingLogType.scopes,
                label: 'SCP',
                count: 3,
                color: PingColors.scopes,
                active: false,
                onTap: () => tapped = true,
              ),
            ],
          ),
        ),
      ));

      await tester.tap(find.text('SCP'));
      expect(tapped, isTrue);
    });

    testWidgets('a count above 99 caps the pill at 99+', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              LogFilterSegment(
                type: PingLogType.scopes,
                label: 'SCP',
                count: 140,
                color: PingColors.scopes,
                active: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ));

      expect(find.text('99+'), findsOneWidget);
    });

    testWidgets('no pill shows when the count is zero', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              LogFilterSegment(
                type: PingLogType.scopes,
                label: 'SCP',
                count: 0,
                color: PingColors.scopes,
                active: true,
                onTap: () {},
              ),
            ],
          ),
        ),
      ));

      expect(find.text('0'), findsNothing);
    });
  });

  group('filterUnifiedPingLog', () {
    test('toggling scopes off hides scope entries, keeping the rest', () {
      final scope = _entry();
      final scopeUnified = UnifiedPingLogEntry(
          type: PingLogType.scopes, timestamp: scope.timestamp, entry: scope);
      final tx = TxLogEntry(
        timestamp: DateTime(2026, 9, 26, 10),
        latitude: 45.1,
        longitude: -75.2,
        power: 0.3,
        events: const [],
      );
      final txUnified = UnifiedPingLogEntry(
          type: PingLogType.tx, timestamp: tx.timestamp, entry: tx);
      final all = [scopeUnified, txUnified];

      const everyType = {
        PingLogType.tx,
        PingLogType.rx,
        PingLogType.disc,
        PingLogType.trace,
        PingLogType.scopes,
      };
      expect(filterUnifiedPingLog(all, everyType), all);

      const withoutScopes = {
        PingLogType.tx,
        PingLogType.rx,
        PingLogType.disc,
        PingLogType.trace,
      };
      expect(filterUnifiedPingLog(all, withoutScopes), [txUnified]);
    });
  });

  group('scopeEntryMatchesSearch', () {
    test('an empty query matches everything', () {
      expect(scopeEntryMatchesSearch(_entry(), ''), isTrue);
    });

    test('matches the repeater id, case-insensitively', () {
      expect(scopeEntryMatchesSearch(_entry(repeaterId: 'AB'), 'ab'), isTrue);
    });

    test('matches a scope name, case-sensitively', () {
      final entry = _entry(scopes: const ['Ottawa', 'west']);
      expect(scopeEntryMatchesSearch(entry, 'Ottawa'), isTrue);
      expect(scopeEntryMatchesSearch(entry, 'ottawa'), isFalse);
    });

    test('matches the outcome words, case-insensitively', () {
      final entry = _entry(outcome: ScopeLogOutcome.noResponse);
      expect(scopeEntryMatchesSearch(entry, 'no response'), isTrue);
    });

    test('no match falls through to false', () {
      expect(scopeEntryMatchesSearch(_entry(), 'nowhere'), isFalse);
    });
  });

  group('ScopeLogCard', () {
    testWidgets('shows the SCP badge, time, location and repeater id',
        (tester) async {
      final entry = _entry(scopes: const ['Ottawa']);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
      ));

      expect(find.text('SCP'), findsOneWidget);
      expect(find.text(entry.timeString), findsOneWidget);
      expect(find.text(entry.locationString), findsOneWidget);
      expect(find.text('AB'), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      testWidgets(
          'the SCP label and scope chips use the ${brightness.name} ink',
          (tester) async {
        final entry = _entry(scopes: const ['Ottawa']);
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
        ));
        final ink = PingColors.scopesFor(brightness);
        expect(tester.widget<Text>(find.text('SCP')).style?.color, ink);
        expect(tester.widget<Text>(find.text('Ottawa')).style?.color, ink);
      });
    }

    testWidgets('an answered card shows its scope names exactly, case kept',
        (tester) async {
      final entry = _entry(scopes: const ['Ottawa', '*', 'west']);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
      ));

      expect(find.text('Answered'), findsOneWidget);
      expect(find.text('Ottawa'), findsOneWidget);
      expect(find.text('*'), findsOneWidget);
      expect(find.text('west'), findsOneWidget);
      expect(find.text('Carries no scopes'), findsNothing);
    });

    testWidgets('an empty answer shows "Carries no scopes"', (tester) async {
      final entry = _entry(scopes: const []);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
      ));

      expect(find.text('Carries no scopes'), findsOneWidget);
    });

    testWidgets('a no-response outcome shows its own words, no scope section',
        (tester) async {
      final entry = _entry(outcome: ScopeLogOutcome.noResponse, scopes: null);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: ScopeLogCard(entry: entry, onTap: () {})),
      ));

      expect(find.text('No response from repeater'), findsOneWidget);
      expect(find.text('Carries no scopes'), findsNothing);
    });

    testWidgets('tapping the card calls onTap', (tester) async {
      var tapped = false;
      final entry = _entry();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ScopeLogCard(entry: entry, onTap: () => tapped = true)),
      ));

      await tester.tap(find.byType(ScopeLogCard));
      expect(tapped, isTrue);
    });
  });

  group('buildAllPingsCsv (the unfiltered "Copy CSV" export)', () {
    test(
        'a scope row is byte-identical to the filtered/searched export\'s '
        'UnifiedPingLogEntry.toCsv() row for the same entry', () {
      final entry = _entry(scopes: const ['Ottawa', '*']);
      final unifiedRow = _scopeUnified(entry).toCsv();

      final csv = buildAllPingsCsv(
        tx: const [],
        rx: const [],
        disc: const [],
        trace: const [],
        scopes: [entry],
      );

      expect(unifiedRow, startsWith('SCOPES,'));
      expect(csv, contains(unifiedRow));
    });

    test('omits the SCP section entirely when there are no scope entries', () {
      final csv = buildAllPingsCsv(
        tx: const [],
        rx: const [],
        disc: const [],
        trace: const [],
        scopes: const [],
      );
      expect(csv, isNot(contains('SCP')));
    });

    test('every scope row in a multi-entry export carries the SCOPES prefix',
        () {
      final ottawa = _entry(repeaterId: 'AB', scopes: const ['Ottawa']);
      final noReply = _entry(
          repeaterId: 'CD',
          outcome: ScopeLogOutcome.noResponse,
          timestamp: DateTime(2026, 9, 26, 9, 5));

      final csv = buildAllPingsCsv(
        tx: const [],
        rx: const [],
        disc: const [],
        trace: const [],
        scopes: [ottawa, noReply],
      );

      final rows = csv
          .split('\n')
          .where((line) => line.isNotEmpty && !line.startsWith('---'))
          .skip(1) // the header row
          .toList();
      expect(rows, hasLength(2));
      for (final row in rows) {
        expect(row, startsWith('SCOPES,'));
      }
    });
  });
}
