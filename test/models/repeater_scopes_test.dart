import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/models/repeater_scope.dart';
import 'package:mesh_mapper/widgets/repeater_scope_chips.dart';

Map<String, dynamic> _base([Map<String, dynamic> extra = const {}]) => {
      'id': 'r1',
      'hex_id': 'AB',
      'name': 'Hill',
      'lat': 45.0,
      'lon': -75.0,
      'last_heard': 1,
      'enabled': 1,
      ...extra,
    };

void main() {
  group('parsing', () {
    test('an older server sends no scope fields: no chips', () {
      final r = Repeater.fromJson(_base());
      expect(r.scopes, isEmpty);
      expect(r.defaultScopeState, isNull);
      expect(r.scopeChips, isEmpty);
    });

    test('reads every source and the default fields', () {
      final r = Repeater.fromJson(_base({
        'scopes': [
          {
            'scope': 'ottawa',
            'observed_at': 1700000000,
            'observed_pkts': 12,
            'proof': 'multibyte',
            'reported_at': null,
            'uploaded_at': 1700000100,
          },
          {'scope': '*', 'reported_at': 1700000200},
        ],
        'default_scope': 'ottawa',
        'default_scope_state': 'named',
        'default_scope_at': 1700000300,
        'default_scope_src': 'advert',
      }));
      expect(r.scopes.map((s) => s.name), ['ottawa', '*']);
      final o = r.scopes.first;
      expect(o.observedAt, 1700000000);
      expect(o.observedPkts, 12);
      expect(o.proof, 'multibyte');
      expect(o.reportedAt, isNull);
      expect(o.uploadedAt, 1700000100);
      expect(o.sourceCount, 2);
      expect(r.defaultScope, 'ottawa');
      expect(r.defaultScopeAt, 1700000300);
    });

    test('malformed scopes are ignored, not thrown', () {
      for (final bad in [
        'ottawa',
        42,
        {'scope': 'x'},
        [null, 3, 'x', {'scope': ''}, {'scope': 7}, {'no': 'name'}],
      ]) {
        final r = Repeater.fromJson(_base({'scopes': bad}));
        expect(r.scopes, isEmpty, reason: '$bad');
      }
    });

    test('a repeated name keeps its first entry', () {
      final list = RepeaterScope.listFromJson([
        {'scope': 'a', 'reported_at': 5},
        {'scope': 'a', 'uploaded_at': 6},
      ]);
      expect(list, hasLength(1));
      expect(list.single.reportedAt, 5);
      expect(list.single.uploadedAt, isNull);
    });

    test('scope fields survive the cache round trip', () {
      final r = Repeater.fromJson(_base({
        'scopes': [
          {'scope': 'ottawa', 'reported_at': 1700000000},
        ],
        'default_scope_state': 'none',
        'default_scope_src': 'reported',
      }));
      final back = Repeater.fromJson(r.toJson());
      expect(back.scopes.single.name, 'ottawa');
      expect(back.scopes.single.reportedAt, 1700000000);
      expect(back.defaultScopeState, 'none');
      expect(back.defaultScopeSrc, 'reported');
    });

    test('no scope keys are written when there are none', () {
      final json = Repeater.fromJson(_base()).toJson();
      expect(json.containsKey('scopes'), isFalse);
      expect(json.containsKey('default_scope_state'), isFalse);
    });
  });

  group('chips', () {
    test('star on the default, then more sources, then name', () {
      final chips = repeaterScopeChips(
        scopes: const [
          RepeaterScope(name: 'zeta', reportedAt: 1, uploadedAt: 2),
          RepeaterScope(name: 'alpha', reportedAt: 1),
          RepeaterScope(name: 'Beta', uploadedAt: 1),
          RepeaterScope(name: 'home', reportedAt: 1),
        ],
        defaultScope: 'home',
        defaultScopeState: 'named',
      );
      expect(chips.map((c) => c.label), ['home', 'zeta', 'alpha', 'Beta']);
      expect(chips.first.isDefault, isTrue);
      expect(chips.skip(1).any((c) => c.isDefault), isFalse);
    });

    test('* reads Not set, never all, and takes the star for state none', () {
      final chips = repeaterScopeChips(
        scopes: const [RepeaterScope(name: '*', reportedAt: 1)],
        defaultScopeState: 'none',
      );
      expect(chips.single.label, 'Not set');
      expect(chips.single.isDefault, isTrue);
      expect(chips.single.details.first, startsWith('Passes messages that'));
      expect(chips.single.label.toLowerCase(), isNot(contains('all')));
    });

    test('a named default with no scope entry still gets its own chip', () {
      final chips = repeaterScopeChips(
        scopes: const [],
        defaultScope: 'gatineau',
        defaultScopeState: 'named',
        defaultScopeSrc: 'reported',
      );
      expect(chips.single.label, 'gatineau');
      expect(chips.single.isDefault, isTrue);
      expect(chips.single.details.single, contains('its observer report'));
    });

    test('an unconfirmed default shows a starred question mark', () {
      final chips = repeaterScopeChips(
        scopes: const [],
        defaultScopeState: 'unknown',
      );
      expect(chips.single.label, '?');
      expect(chips.single.isDefault, isTrue);
    });

    test('details name each source', () {
      final chip = repeaterScopeChips(scopes: const [
        RepeaterScope(
            name: 'x',
            observedAt: 1,
            observedPkts: 1,
            proof: 'firmware',
            reportedAt: 1,
            uploadedAt: 1),
      ]).single;
      expect(chip.details, hasLength(3));
      expect(chip.details[0], contains('Seen forwarding 1 packet'));
      expect(chip.details[0], contains('its firmware version'));
      expect(chip.details[1], startsWith('Reported'));
      expect(chip.details[2], startsWith("Uploaded by a wardriver's app"));
    });
  });

  group('widget', () {
    Future<void> pump(WidgetTester tester, List<RepeaterScopeChip> chips) =>
        tester.pumpWidget(MaterialApp(
          home: Scaffold(body: RepeaterScopeChips(chips: chips)),
        ));

    testWidgets('folds after four and expands on tap', (tester) async {
      final chips = repeaterScopeChips(scopes: [
        for (final n in ['a', 'b', 'c', 'd', 'e', 'f'])
          RepeaterScope(name: n, reportedAt: 1),
      ]);
      await pump(tester, chips);
      expect(find.text('a'), findsOneWidget);
      expect(find.text('e'), findsNothing);
      expect(find.text('+2 more'), findsOneWidget);
      await tester.tap(find.text('+2 more'));
      await tester.pump();
      expect(find.text('f'), findsOneWidget);
      expect(find.text('+2 more'), findsNothing);
    });

    testWidgets('tapping a chip shows where it came from', (tester) async {
      await pump(
          tester,
          repeaterScopeChips(
              scopes: const [RepeaterScope(name: 'ottawa', uploadedAt: 1)]));
      await tester.tap(find.text('ottawa'));
      await tester.pumpAndSettle();
      expect(find.textContaining("Uploaded by a wardriver's app"),
          findsOneWidget);
    });
  });
}
