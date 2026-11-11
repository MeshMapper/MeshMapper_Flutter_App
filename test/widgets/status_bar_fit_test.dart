import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/models/ping_data.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/widgets/status_bar.dart';

/// Renders the real [StatusBar] at real phone widths with the real Roboto and
/// Material Icons fonts from the Flutter SDK (the test font draws every glyph
/// as a square, so widths would be meaningless without them), and checks the
/// row never overflows. Skipped when the SDK fonts cannot be found.

const _fontNames = {
  'Roboto': [
    'Roboto-Regular.ttf',
    'Roboto-Medium.ttf',
    'Roboto-Bold.ttf',
  ],
  'MaterialIcons': ['MaterialIcons-Regular.otf'],
};

String? _fontDir() {
  final root = Platform.environment['FLUTTER_ROOT'];
  if (root == null) return null;
  final dir = '$root/bin/cache/artifacts/material_fonts';
  final ok = _fontNames.values
      .expand((f) => f)
      .every((f) => File('$dir/$f').existsSync());
  return ok ? dir : null;
}

Future<void> _loadFonts(String dir) async {
  for (final entry in _fontNames.entries) {
    final loader = FontLoader(entry.key);
    for (final file in entry.value) {
      final bytes = File('$dir/$file').readAsBytesSync();
      loader.addFont(Future.value(ByteData.sublistView(bytes)));
    }
    await loader.load();
  }
}

/// Only the getters the status bar reads.
class _FakeAppState extends ChangeNotifier implements AppStateProvider {
  _FakeAppState({
    required this.pingStats,
    this.autoMode = AutoMode.passive,
    this.scopeDiscoveryActive = false,
  });

  @override
  final PingStats pingStats;
  @override
  final AutoMode autoMode;
  @override
  final bool scopeDiscoveryActive;

  @override
  bool get offlineMode => false;
  @override
  GpsStatus get gpsStatus => GpsStatus.locked;
  @override
  bool? get inZone => true;
  @override
  String? get zoneCode => 'YOW';
  @override
  String? get shortZoneCode => 'YOW';
  @override
  bool get isConnected => true;
  @override
  bool get floodDisabled => false;
  @override
  bool get txAllowed => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

PingStats _stats(int tx, int rx, int disc, int trace, int scope, int up) =>
    PingStats(
      txCount: tx,
      rxCount: rx,
      discCount: disc,
      traceCount: trace,
      scopeCount: scope,
      successfulUploads: up,
    );

/// Counts with the given number of digits, mixed like a real drive.
PingStats _digits(int n) => switch (n) {
      1 => _stats(9, 7, 8, 6, 5, 9),
      2 => _stats(42, 37, 88, 12, 23, 99),
      3 => _stats(142, 337, 210, 104, 151, 389),
      4 => _stats(9876, 8765, 7654, 6543, 5432, 9999),
      _ => _stats(9876543, 8765432, 7654321, 6543210, 5432109, 9999999),
    };

enum _Slot { trace, scope, hidden }

/// [slot] picks the mode and switch that lead to it. Hidden also needs no
/// scope counted this session, since a count keeps the Scope chip up.
_FakeAppState _app(PingStats stats, _Slot slot) => _FakeAppState(
      pingStats: slot == _Slot.hidden ? stats.copyWith(scopeCount: 0) : stats,
      autoMode: slot == _Slot.trace ? AutoMode.targeted : AutoMode.passive,
      scopeDiscoveryActive: slot == _Slot.scope,
    );

/// Pumps the bar at [width] and returns the spare width: what is left of
/// the row after the region chip, the gap and the stats at their natural
/// (unscaled) size. Negative means the FittedBox had to shrink the stats.
Future<double> _pumpBar(WidgetTester tester, double width, _FakeAppState app,
    double textScale) async {
  tester.view.devicePixelRatio = 3;
  tester.view.physicalSize = Size(width * 3, 300 * 3);
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ChangeNotifierProvider<AppStateProvider>.value(
      value: app,
      child: MaterialApp(
        theme: ThemeData(fontFamily: 'Roboto'),
        home: MediaQuery(
          data: MediaQueryData(
            size: Size(width, 300),
            textScaler: TextScaler.linear(textScale),
          ),
          child: const Scaffold(
            body: Align(alignment: Alignment.topCenter, child: StatusBar()),
          ),
        ),
      ),
    ),
  );
  await tester.pump();

  expect(tester.takeException(), isNull,
      reason: 'overflow at $width px, scale $textScale');

  final bar = tester.getRect(find.byType(StatusBar));
  final stats = find.byKey(const ValueKey('status-bar-stats'));
  final statsRect = tester.getRect(stats);
  // Every chip stays on screen.
  expect(statsRect.right, lessThanOrEqualTo(bar.right + 0.01));
  expect(statsRect.left, greaterThanOrEqualTo(bar.left - 0.01));

  final naturalStats = tester.getSize(stats).width;
  final region = tester
      .getSize(find
          .ancestor(of: find.text('YOW'), matching: find.byType(Container))
          .first)
      .width;
  // Bar padding 10 each side, gap 5 between region and stats.
  return bar.width - 20 - region - 5 - naturalStats;
}

void main() {
  final fontDir = _fontDir();
  final skip = fontDir == null ? 'Flutter SDK material fonts not found' : null;

  setUpAll(() async {
    if (fontDir != null) await _loadFonts(fontDir);
  });

  for (final width in [320.0, 375.0, 393.0]) {
    for (final digits in [1, 2, 3, 4, 7]) {
      for (final slot in _Slot.values) {
        for (final scale in [1.0, 1.3]) {
          testWidgets(
              'no overflow at ${width.toInt()} px, $digits-digit counts, '
              '${slot.name}, text x$scale', (tester) async {
            final spare = await _pumpBar(
                tester, width, _app(_digits(digits), slot), scale);
            // At normal text the counts this phone sees in a drive (up to
            // 4 digits, shortened to "9.9k") fit on a 375 pt phone without
            // any shrinking.
            if (width >= 375 && scale == 1.0 && digits <= 4) {
              expect(spare, greaterThanOrEqualTo(0),
                  reason: 'stats had to shrink at $width px');
            }
            if (width == 375 && scale == 1.0) {
              // ignore: avoid_print
              print('[fit] 375 px $digits digits ${slot.name}: '
                  'spare ${spare.toStringAsFixed(1)} px');
            }
          }, skip: skip != null);
        }
      }
    }
  }

  testWidgets('a swap between Trace and Scope keeps both counts',
      (tester) async {
    final stats = _stats(1, 2, 3, 44, 55, 6);
    final route = find.byIcon(Icons.route);
    final scope = find.byIcon(Icons.travel_explore);

    await _pumpBar(tester, 375, _app(stats, _Slot.trace), 1);
    expect(route, findsOneWidget);
    expect(scope, findsNothing);
    expect(find.text('44'), findsOneWidget);

    // Trace mode left, scope discovery on: Scope takes the slot.
    await _pumpBar(tester, 375, _app(stats, _Slot.scope), 1);
    expect(scope, findsOneWidget);
    expect(route, findsNothing);
    expect(find.text('55'), findsOneWidget);

    // Scope discovery off again: the session's count keeps it up.
    await _pumpBar(tester, 375,
        _FakeAppState(pingStats: stats, scopeDiscoveryActive: false), 1);
    expect(scope, findsOneWidget);
    expect(find.text('55'), findsOneWidget);

    // Nothing counted and neither mode: the slot is gone.
    await _pumpBar(tester, 375, _app(stats, _Slot.hidden), 1);
    expect(scope, findsNothing);
    expect(route, findsNothing);
  });

  testWidgets('counts from 1000 are shortened', (tester) async {
    await _pumpBar(tester, 375,
        _app(_stats(1400, 999, 12345, 0, 1234567, 1000), _Slot.scope), 1);
    expect(find.text('1.4k'), findsOneWidget);
    expect(find.text('999'), findsOneWidget);
    expect(find.text('12k'), findsOneWidget);
    expect(find.text('1.2M'), findsOneWidget);
    expect(find.text('1.0k'), findsOneWidget);
  });
}
