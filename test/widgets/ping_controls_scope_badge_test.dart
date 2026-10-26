import 'dart:ui' show SemanticsAction, Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/utils/ping_colors.dart';
import 'package:mesh_mapper/widgets/ping_controls.dart';

/// The "Scopes" badge (owner ruling 15): a small pill at the corner of the
/// running mode's button while the app is asking a discovered repeater for
/// its scopes ([AppStateProvider.isScopeRequestActive]).
///
/// `PingControls`, `CompactPingControls` and `LandscapePingControls` all read
/// a live `AppStateProvider`, which no test in this suite can build, so the
/// rendered tests below pump the exact button widgets those three layouts use
/// ([PingActionButton] for portrait, [LandscapePingIconButton] for
/// landscape, [CompactPingActionButton] for compact), each fed by
/// [showsScopesBadge] for its mode, the same decision every layout's call
/// site routes through.
void main() {
  group('showsScopesBadge', () {
    test('Passive: shows while running and a scope request is active', () {
      expect(
        showsScopesBadge(AutoMode.passive,
            isModeRunning: true, isScopeRequestActive: true),
        isTrue,
      );
    });

    test('Passive: hidden once the scope request ends', () {
      expect(
        showsScopesBadge(AutoMode.passive,
            isModeRunning: true, isScopeRequestActive: false),
        isFalse,
      );
    });

    test('Passive: hidden when Passive is not the running mode', () {
      expect(
        showsScopesBadge(AutoMode.passive,
            isModeRunning: false, isScopeRequestActive: true),
        isFalse,
      );
    });

    test('Hybrid: shows while running and a scope request is active', () {
      expect(
        showsScopesBadge(AutoMode.hybrid,
            isModeRunning: true, isScopeRequestActive: true),
        isTrue,
      );
    });

    test('Hybrid: hidden once the scope request ends', () {
      expect(
        showsScopesBadge(AutoMode.hybrid,
            isModeRunning: true, isScopeRequestActive: false),
        isFalse,
      );
    });

    test('Hybrid: hidden when Hybrid is not the running mode', () {
      expect(
        showsScopesBadge(AutoMode.hybrid,
            isModeRunning: false, isScopeRequestActive: true),
        isFalse,
      );
    });

    test('Active: never shows, even while "running" with a request active',
        () {
      expect(
        showsScopesBadge(AutoMode.active,
            isModeRunning: true, isScopeRequestActive: true),
        isFalse,
      );
    });

    test('Trace: never shows, even while "running" with a request active',
        () {
      expect(
        showsScopesBadge(AutoMode.targeted,
            isModeRunning: true, isScopeRequestActive: true),
        isFalse,
      );
    });
  });

  group('scopesBadgeSemanticsLabel', () {
    test('leaves the label untouched while inactive', () {
      expect(scopesBadgeSemanticsLabel('Passive Mode', false), 'Passive Mode');
    });

    test('appends the exact phrase while active, keeping the base label',
        () {
      expect(
        scopesBadgeSemanticsLabel('Passive Mode', true),
        'Passive Mode, asking repeaters for scopes',
      );
    });

    test(
        'a countdown baked into the label keeps its text and gains the same '
        'suffix', () {
      // Landscape's tooltip base and compact's expanded label can both carry
      // a live countdown baked into the string; the composer must not touch
      // that text, only append to it.
      expect(
        scopesBadgeSemanticsLabel('Listening 5s', true),
        'Listening 5s, asking repeaters for scopes',
      );
      expect(scopesBadgeSemanticsLabel('Listening 5s', false), 'Listening 5s');
    });

    test('suffix constant matches the phrase the review required', () {
      expect(scopesBadgeSemanticsSuffix, ', asking repeaters for scopes');
    });
  });

  group('ScopesBadge widget', () {
    testWidgets('renders the pill text in the PingColors.scopes accent',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: ScopesBadge()),
      ));

      expect(find.text('Scopes'), findsOneWidget);

      final container = tester.widget<Container>(
        find.descendant(
          of: find.byType(ScopesBadge),
          matching: find.byType(Container),
        ),
      );
      final decoration = container.decoration as BoxDecoration;
      expect(decoration.color, PingColors.scopes);
    });
  });

  group('rendered buttons (portrait, landscape, compact)', () {
    for (final layout in _Layout.values) {
      group(layout.name, () {
        for (final mode in [AutoMode.passive, AutoMode.hybrid]) {
          testWidgets('${mode.name}: the pill shows while asking, not after',
              (tester) async {
            await _pump(tester, layout, mode, requestActive: true);
            expect(_badgeIn(layout), findsOneWidget);
            expect(
              find.descendant(
                  of: find.byType(layout.buttonType),
                  matching: find.text('Scopes')),
              findsOneWidget,
            );

            await _pump(tester, layout, mode, requestActive: false);
            expect(_badgeIn(layout), findsNothing);
            expect(find.text('Scopes'), findsNothing);
          });

          testWidgets('${mode.name}: label and countdown text are unchanged',
              (tester) async {
            await _pump(tester, layout, mode, requestActive: false);
            final off = _buttonTexts(tester, layout);
            await _pump(tester, layout, mode, requestActive: true);
            final on = _buttonTexts(tester, layout);
            expect(off, isNotEmpty);
            expect(on, off);
          });

          testWidgets('${mode.name}: semantics carry the phrase only while on',
              (tester) async {
            final handle = tester.ensureSemantics();
            final phrase = RegExp(RegExp.escape(scopesBadgeSemanticsSuffix));

            await _pump(tester, layout, mode, requestActive: true);
            final node = tester.getSemantics(find.bySemanticsLabel(phrase));
            expect(
              node.label,
              contains('${layout.baseLabel(mode)}$scopesBadgeSemanticsSuffix'),
            );

            await _pump(tester, layout, mode, requestActive: false);
            expect(find.bySemanticsLabel(phrase), findsNothing);
            // The button still announces its own label, first.
            expect(
              find.bySemanticsLabel(
                  RegExp('^${RegExp.escape(layout.baseLabel(mode))}')),
              findsWidgets,
            );
            handle.dispose();
          });

          if (layout != _Layout.landscape) {
            testWidgets('${mode.name}: the label is read once, badge on or off',
                (tester) async {
              final handle = tester.ensureSemantics();
              final base = layout.baseLabel(mode);
              for (final requestActive in [false, true]) {
                await _pump(tester, layout, mode, requestActive: requestActive);
                final node = tester.getSemantics(find
                    .bySemanticsLabel(RegExp('^${RegExp.escape(base)}'))
                    .first);
                final label = node.label;
                expect(RegExp(RegExp.escape(base)).allMatches(label).length, 1,
                    reason: 'the base label must not repeat: "$label"');
                expect(label, isNot(contains('Scopes')),
                    reason: 'the pill text is read through the suffix only');
                expect(
                    label.startsWith(
                        scopesBadgeSemanticsLabel(base, requestActive)),
                    isTrue,
                    reason: label);
                // Still a tappable, enabled button for TalkBack and VoiceOver.
                final data = node.getSemanticsData();
                expect(data.flagsCollection.isButton, isTrue);
                expect(data.flagsCollection.isEnabled, Tristate.isTrue);
                expect(data.hasAction(SemanticsAction.tap), isTrue);
              }
              handle.dispose();
            });
          }

          testWidgets('${mode.name}: the overhanging pill is not clipped',
              (tester) async {
            await _pump(tester, layout, mode, requestActive: true);
            final badge = _badgeIn(layout);

            // Every Stack between the pill and the button lets it overhang.
            final stacks = find.ancestor(
                of: badge,
                matching: find.descendant(
                    of: find.byType(layout.buttonType),
                    matching: find.byType(Stack)));
            expect(stacks, findsWidgets);
            for (final stack in tester.widgetList<Stack>(stacks)) {
              expect(stack.clipBehavior, Clip.none);
            }
            // And no clip widget sits between them either.
            for (final clip in [ClipRect, ClipRRect, ClipPath, ClipOval]) {
              expect(
                find.ancestor(
                    of: badge,
                    matching: find.descendant(
                        of: find.byType(layout.buttonType),
                        matching: find.byType(clip))),
                findsNothing,
              );
            }

            // The pill really does sit past its Stack's edge, so a clip on
            // that Stack would cut it.
            final stackRect = tester.getRect(stacks.first);
            final badgeRect = tester.getRect(badge);
            expect(stackRect.intersect(badgeRect), isNot(badgeRect));
          });
        }

        for (final mode in [AutoMode.active, AutoMode.targeted]) {
          testWidgets('${mode.name}: never shows the pill', (tester) async {
            final handle = tester.ensureSemantics();
            await _pump(tester, layout, mode, requestActive: true);
            expect(_badgeIn(layout), findsNothing);
            expect(find.text('Scopes'), findsNothing);
            expect(
              find.bySemanticsLabel(
                  RegExp(RegExp.escape(scopesBadgeSemanticsSuffix))),
              findsNothing,
            );
            handle.dispose();
          });
        }
      });
    }
  });
}

/// The three layouts and the button widget each one renders.
enum _Layout {
  portrait(PingActionButton),
  landscape(LandscapePingIconButton),
  compact(CompactPingActionButton);

  const _Layout(this.buttonType);

  final Type buttonType;

  /// The button's own text: the running label in portrait and compact, the
  /// tooltip in landscape (whose countdown rides a separate number badge).
  String baseLabel(AutoMode mode) => switch (this) {
        _Layout.landscape => '${_modeName(mode)} Mode',
        _ => 'Next ping 12s',
      };
}

String _modeName(AutoMode mode) => switch (mode) {
      AutoMode.active => 'Active',
      AutoMode.hybrid => 'Hybrid',
      AutoMode.passive => 'Passive',
      AutoMode.targeted => 'Trace',
    };

IconData _iconFor(AutoMode mode) => switch (mode) {
      AutoMode.active => Icons.sensors,
      AutoMode.hybrid => Icons.compare_arrows,
      AutoMode.passive => Icons.hearing,
      AutoMode.targeted => Icons.route,
    };

/// Pumps [layout]'s real button for a running [mode], with the badge decided
/// by [showsScopesBadge] exactly as the layouts' call sites decide it.
Future<void> _pump(
  WidgetTester tester,
  _Layout layout,
  AutoMode mode, {
  required bool requestActive,
}) async {
  final badge = showsScopesBadge(mode,
      isModeRunning: true, isScopeRequestActive: requestActive);
  const color = Color(0xFF22C55E);
  final label = layout.baseLabel(mode);
  final Widget button = switch (layout) {
    _Layout.portrait => PingActionButton(
        icon: _iconFor(mode),
        label: label,
        color: color,
        enabled: true,
        isActive: true,
        onPressed: () {},
        showScopesBadge: badge,
      ),
    _Layout.landscape => LandscapePingIconButton(
        icon: _iconFor(mode),
        tooltip: label,
        color: color,
        enabled: true,
        isActive: true,
        countdown: 12,
        onPressed: () {},
        showScopesBadge: badge,
      ),
    _Layout.compact => CompactPingActionButton(
        icon: _iconFor(mode),
        label: label,
        color: color,
        enabled: true,
        isActive: true,
        isExpanded: true,
        progress: 0.5,
        onPressed: () {},
        showScopesBadge: badge,
      ),
  };
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: SizedBox(width: 160, child: button),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

Finder _badgeIn(_Layout layout) => find.descendant(
    of: find.byType(layout.buttonType), matching: find.byType(ScopesBadge));

/// Every Text the button renders, minus the pill's own.
List<String?> _buttonTexts(WidgetTester tester, _Layout layout) {
  final pillTexts = tester
      .widgetList<Text>(find.descendant(
          of: find.byType(ScopesBadge), matching: find.byType(Text)))
      .toSet();
  return tester
      .widgetList<Text>(find.descendant(
          of: find.byType(layout.buttonType), matching: find.byType(Text)))
      .where((t) => !pillTexts.contains(t))
      .map((t) => t.data)
      .toList();
}
