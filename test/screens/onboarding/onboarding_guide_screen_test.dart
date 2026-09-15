import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/models/user_preferences.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/screens/onboarding/onboarding_guide_pages.dart';
import 'package:mesh_mapper/screens/onboarding/onboarding_guide_screen.dart';
import 'package:mesh_mapper/utils/ping_colors.dart';
import 'package:provider/provider.dart';

Widget host({TargetPlatform platform = TargetPlatform.android}) {
  return MaterialApp(
    theme: ThemeData(platform: platform, useMaterial3: true),
    home: const OnboardingGuideScreen(),
  );
}

Future<void> goForward(WidgetTester tester, int times) async {
  for (var i = 0; i < times; i++) {
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }
}

void main() {
  testWidgets('page 7 locks setup and swiping during completion',
      (tester) async {
    final persistence = Completer<bool>();
    final appState = _UnusedAppState();
    addTearDown(appState.dispose);
    OnboardingGuideResult? result;
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: appState,
        child: MaterialApp(
          theme: ThemeData(platform: TargetPlatform.iOS),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  result =
                      await Navigator.of(context).push<OnboardingGuideResult>(
                    MaterialPageRoute(
                      builder: (_) => OnboardingGuideScreen(
                        complete: () => persistence.future,
                      ),
                    ),
                  );
                },
                child: const Text('Open Guide'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open Guide'));
    await tester.pumpAndSettle();
    await goForward(tester, 6);
    final setup = find.text('Set Up Background Location');
    await tester.ensureVisible(setup);
    await tester.tap(setup);
    await tester.pumpAndSettle();
    expect(find.text('Background Location'), findsOneWidget);
    await tester.tap(find.text('Not Now'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(PageView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Page 8 of 12'), findsOneWidget);
    await tester.drag(find.byType(PageView), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(find.text('Page 7 of 12'), findsOneWidget);
    await tester.ensureVisible(setup);
    await tester.tap(find.text('Skip Guide'));
    await tester.pump();

    // Use coordinates because the locked page intentionally fails hit testing.
    await tester.tapAt(tester.getCenter(setup));
    await tester.pumpAndSettle();
    expect(find.text('Background Location'), findsNothing);
    await tester.dragFrom(
      tester.getCenter(find.byType(PageView)),
      const Offset(-600, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Page 7 of 12'), findsOneWidget);
    expect(result, isNull);

    persistence.complete(true);
    await tester.pumpAndSettle();
    expect(result, OnboardingGuideResult.skipped);
    expect(find.byType(OnboardingGuideScreen), findsNothing);
    expect(find.text('Open Guide'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows the approved first page and progress', (tester) async {
    await tester.pumpWidget(host());

    expect(find.text('Connect Your MeshCore Radio'), findsOneWidget);
    expect(find.text('Page 1 of 12'), findsOneWidget);
    expect(find.text('Skip Guide'), findsOneWidget);
    expect(find.text('Back'), findsNothing);
    expect(find.text('Next'), findsOneWidget);
  });

  testWidgets('first page mirrors both Connection screen states',
      (tester) async {
    await tester.pumpWidget(host());

    final disconnected = find.byKey(
      const ValueKey('guide-disconnected-connection-preview'),
    );
    final connected = find.byKey(
      const ValueKey('guide-connected-connection-preview'),
    );

    expect(disconnected, findsOneWidget);
    expect(connected, findsOneWidget);

    for (final label in <String>[
      'Connection',
      'Last Connected Device',
      'MeshCore Radio',
      'Reconnect',
      'Scan',
      'Forget',
      'Go Offline',
      'BLE',
      'TCP',
    ]) {
      expect(
        find.descendant(of: disconnected, matching: find.text(label)),
        findsWidgets,
        reason: 'The disconnected preview should show $label.',
      );
    }

    for (final label in <String>[
      'Connection',
      'MeshCore Radio',
      'Connected',
      'Power Level',
      'Radio',
      'Go Offline',
      'Disconnect',
    ]) {
      expect(
        find.descendant(of: connected, matching: find.text(label)),
        findsWidgets,
        reason: 'The connected preview should show $label.',
      );
    }

    final disconnectedNav = find.byKey(
      const ValueKey('guide-disconnected-connection-nav'),
    );
    final connectedNav = find.byKey(
      const ValueKey('guide-connected-connection-nav'),
    );
    final disconnectedLabels = <String>[
      'Map',
      'Log',
      'History',
      'Connect',
      'Settings',
    ];
    final connectedLabels = <String>[
      'Map',
      'Log',
      'History',
      'Connected',
      'Settings',
    ];

    for (final (nav, labels) in <(Finder, List<String>)>[
      (disconnectedNav, disconnectedLabels),
      (connectedNav, connectedLabels),
    ]) {
      final positions = labels
          .map(
            (label) => tester.getCenter(
              find.descendant(of: nav, matching: find.text(label)),
            ),
          )
          .toList();
      for (var index = 1; index < positions.length; index++) {
        expect(
          positions[index - 1].dx,
          lessThan(positions[index].dx),
          reason: 'The Connection navigation should match the app order.',
        );
      }
    }
  });

  testWidgets('Next and Back move through the guide', (tester) async {
    await tester.pumpWidget(host());

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Is Your Antenna Exposed?'), findsOneWidget);
    expect(find.text('Page 2 of 12'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);

    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Connect Your MeshCore Radio'), findsOneWidget);
    expect(find.text('Page 1 of 12'), findsOneWidget);
  });

  testWidgets('Skip Guide returns the skipped result', (tester) async {
    OnboardingGuideResult? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<OnboardingGuideResult>(
                MaterialPageRoute(
                  builder: (_) => const OnboardingGuideScreen(),
                ),
              );
            },
            child: const Text('Open Guide'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip Guide'));
    await tester.pumpAndSettle();

    expect(result, OnboardingGuideResult.skipped);
  });

  testWidgets('Finish Guide returns the finished result', (tester) async {
    OnboardingGuideResult? result;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              result = await Navigator.of(context).push<OnboardingGuideResult>(
                MaterialPageRoute(
                  builder: (_) => const OnboardingGuideScreen(),
                ),
              );
            },
            child: const Text('Open Guide'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open Guide'));
    await tester.pumpAndSettle();
    await goForward(tester, 11);
    await tester.tap(find.text('Finish Guide'));
    await tester.pumpAndSettle();

    expect(result, OnboardingGuideResult.finished);
  });

  testWidgets('Android needs no extra background permission', (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 6);

    expect(
      find.textContaining(
        'No additional background location permission is required',
      ),
      findsOneWidget,
    );
    expect(find.text('Set Up Background Location'), findsNothing);
  });

  testWidgets('iPhone explains Always permission and offers setup',
      (tester) async {
    await tester.pumpWidget(host(platform: TargetPlatform.iOS));
    await goForward(tester, 6);

    expect(
      find.textContaining('allow location access Always'),
      findsOneWidget,
    );
    expect(find.text('Set Up Background Location'), findsOneWidget);
  });

  testWidgets('keeps the required regional and accuracy claims',
      (tester) async {
    await tester.pumpWidget(host());

    await goForward(tester, 2);
    expect(
      find.textContaining('Active Mode is disabled by default in MeshMapper'),
      findsOneWidget,
    );

    await goForward(tester, 2);
    expect(
      find.textContaining('Regional administrators may require Smart Pinging'),
      findsOneWidget,
    );

    await goForward(tester, 1);
    expect(
      find.textContaining('If your CARpeater is not reported'),
      findsOneWidget,
    );

    await goForward(tester, 5);
    expect(
      find.textContaining('cryptographically sign a challenge'),
      findsOneWidget,
    );
  });

  testWidgets('page 3 teaches the modes in airtime order with map icons',
      (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 2);

    const modes = <(String, IconData)>[
      ('Passive Mode', Icons.hearing),
      ('Trace Mode', Icons.gps_fixed),
      ('Hybrid Mode', Icons.compare_arrows),
      ('Active Mode', Icons.sensors),
    ];
    final positions = <Offset>[];
    for (final (title, icon) in modes) {
      final row = find.widgetWithText(GuideIconRow, title);
      expect(row, findsOneWidget);
      expect(
        find.descendant(of: row, matching: find.byIcon(icon)),
        findsOneWidget,
        reason: '$title should use the same icon as the Map controls.',
      );
      positions.add(tester.getCenter(row));
    }
    for (var index = 1; index < positions.length; index++) {
      expect(
        positions[index - 1].dy,
        lessThan(positions[index].dy),
        reason: 'Modes should progress from least to most mesh airtime.',
      );
    }

    for (final claim in <String>[
      'zero-hop discovery request to every repeater that can hear you',
      'each repeater replies directly',
      'most airtime-conservative general mapping mode',
      'Only that repeater responds',
      'most airtime-friendly mode',
      'Alternates between zero-hop discovery requests and channel flood messages',
      'flood messages use more airtime than a zero-hop discovery request',
      'uses the most airtime on the mesh',
      'It only sends channel flood messages that propagate through the mesh',
      'disabled by default in MeshMapper',
      'most aggressive mode',
    ]) {
      expect(find.textContaining(claim), findsOneWidget);
    }

    expect(find.textContaining('Like Active Mode'), findsNothing);
    expect(find.textContaining('or a regional rule'), findsNothing);
  });

  testWidgets('page 3 centralizes regional flood policy in one callout',
      (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 2);

    expect(
      find.textContaining('Regional administrators may disable flood traffic'),
      findsOneWidget,
    );
    expect(
      find.textContaining('hides Hybrid and Active modes'),
      findsOneWidget,
    );
    expect(find.textContaining('preserve airtime'), findsOneWidget);
    expect(
      find.textContaining('reduce the load MeshMapper places on the mesh'),
      findsOneWidget,
    );

    for (final title in <String>[
      'Passive Mode',
      'Trace Mode',
      'Hybrid Mode',
      'Active Mode',
    ]) {
      final row = find.widgetWithText(GuideIconRow, title);
      expect(
        find.descendant(
          of: row,
          matching:
              find.textContaining(RegExp('regional', caseSensitive: false)),
        ),
        findsNothing,
        reason: '$title should explain the mode, not repeat regional policy.',
      );
    }
  });

  testWidgets('page 3 owns the single 25 metre explanation', (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 2);

    expect(
      find.textContaining('at least 25 metres of movement'),
      findsOneWidget,
    );

    await goForward(tester, 2);
    expect(
      find.textContaining('at least 25 metres of movement'),
      findsNothing,
    );
  });

  testWidgets('page 4 identifies Map tab controls without an icon gallery',
      (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 3);

    expect(find.text('Map Tab Controls'), findsOneWidget);
    expect(
      find.textContaining(
        'These buttons are on the Map tab. They control what appears on the map',
      ),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('Map toolbar controls in app order'),
      findsNothing,
    );
  });

  testWidgets('page 5 states the regional Smart Pinging requirement once',
      (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 4);

    expect(
      find.textContaining('Regional administrators may require Smart Pinging'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        RegExp('regional administrator', caseSensitive: false),
      ),
      findsOneWidget,
    );
  });

  testWidgets('CARpeater setup returns to page 6 of the guide', (tester) async {
    final appState = _CarpeaterAppState();
    addTearDown(appState.dispose);
    await tester.pumpWidget(
      ChangeNotifierProvider<AppStateProvider>.value(
        value: appState,
        child: MaterialApp(
          theme: ThemeData(useMaterial3: true),
          home: const OnboardingGuideScreen(),
        ),
      ),
    );
    await goForward(tester, 5);

    final configureButton = find.text('Configure CARpeater');
    await tester.ensureVisible(configureButton);
    await tester.pumpAndSettle();
    await tester.tap(configureButton);
    await tester.pumpAndSettle();
    expect(find.text('My CARpeater'), findsOneWidget);

    const publicKey =
        'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
    await tester.enterText(find.byType(TextField), publicKey);
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(find.text('My CARpeater'), findsNothing);
    expect(find.text('Page 6 of 12'), findsOneWidget);
    expect(appState.preferences.carpeaterPublicKey, publicKey);
    expect(appState.preferences.ignoreCarpeater, isTrue);
  });

  testWidgets('page 8 uses one square coverage legend', (tester) async {
    PingColors.setColorVisionType(ColorVisionType.none);
    await tester.pumpWidget(host());
    await goForward(tester, 7);

    expect(
      find.bySemanticsLabel(
        'MeshMapper result colors for BIDIR, DISC, TX, RX, DEAD, and DROP',
      ),
      findsNothing,
    );

    const expectedColors = <String, Color>{
      'BIDIR': Color(0xFF7EE094),
      'DISC': Color(0xFF51D4E9),
      'TX': Color(0xFFFD8928),
      'RX': Color(0xFF7D54C7),
      'DEAD': Color(0xFF9E9689),
      'DROP': Color(0xFFE04F5D),
    };
    for (final entry in expectedColors.entries) {
      final row = find.byKey(ValueKey('guide-coverage-result-${entry.key}'));
      final swatch = find.descendant(
        of: row,
        matching: find.byKey(
          ValueKey('guide-coverage-swatch-${entry.key}'),
        ),
      );
      expect(row, findsOneWidget);
      expect(swatch, findsOneWidget);

      final decoration = tester.widget<Container>(swatch).decoration;
      expect(decoration, isA<BoxDecoration>());
      final box = decoration! as BoxDecoration;
      expect(box.color, entry.value);
      expect(box.shape, BoxShape.rectangle);
      expect(box.borderRadius, BorderRadius.circular(2));
    }
  });

  testWidgets('page 9 explains online and offline mode availability',
      (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 8);

    final onlineMode = find.widgetWithText(GuideIconRow, 'Online Mode');
    expect(
      find.descendant(
        of: onlineMode,
        matching: find.textContaining(
          'enables Hybrid and Active modes where allowed by your region',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: onlineMode,
        matching: find.textContaining('Smart Pinging is enabled by default'),
      ),
      findsOneWidget,
    );

    final offlineMode = find.widgetWithText(GuideIconRow, 'Offline Mode');
    expect(
      find.descendant(
        of: offlineMode,
        matching: find.textContaining(
          'Only Passive and Trace modes are available',
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('checks out a regional airtime slot'),
      findsWidgets,
    );
    expect(find.textContaining('limit simultaneous flood traffic'),
        findsOneWidget);
    expect(find.textContaining('protect the mesh from excessive load'),
        findsOneWidget);
    expect(
      find.textContaining(
        'Smart Pinging is also unavailable because the app cannot check recent server coverage',
      ),
      findsOneWidget,
    );
  });

  testWidgets('page 10 explains coverage access and public privacy',
      (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 9);

    expect(
      find.textContaining(
        'Coverage collected in Online Mode contributes automatically',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Offline Mode contributes only after you manually upload',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Regional administrators can review detailed GPS coordinates',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('in regions they administer'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'Global administrators can review this information across MeshMapper',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('investigate and remove inaccurate mapping data'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'do not expose your individual coverage points, precise GPS coordinates, or companion public key',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('Do not operate the app while driving'),
        findsNothing);
  });

  testWidgets('keeps the approved setup, results, data, and privacy claims',
      (tester) async {
    await tester.pumpWidget(host());

    expect(
      find.textContaining("It never changes the radio's actual transmit power"),
      findsOneWidget,
    );

    await goForward(tester, 1);
    expect(find.textContaining('External Antenna: Yes / No'), findsOneWidget);

    await goForward(tester, 2);
    expect(find.text('Legend & Info'), findsOneWidget);

    await goForward(tester, 4);
    expect(
      find.textContaining('the message routed through the mesh'),
      findsWidgets,
    );

    await goForward(tester, 1);
    expect(
      find.textContaining('Offline sessions are not uploaded automatically'),
      findsOneWidget,
    );

    await goForward(tester, 1);
    expect(
      find.textContaining('It does not make the device anonymous'),
      findsOneWidget,
    );
  });

  testWidgets('page 11 introduces account benefits without repeating claims',
      (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 10);

    expect(find.text('MyMeshMapper allows you to:'), findsOneWidget);
    expect(find.textContaining('Claim repeaters the user administers'),
        findsNothing);
    expect(find.text('Claim and manage repeaters'), findsOneWidget);
    expect(
      find.textContaining('Once claimed, your MyMeshMapper identity'),
      findsOneWidget,
    );
    expect(
      find.textContaining('add build and deployment information'),
      findsOneWidget,
    );
  });

  testWidgets('final page explains bug reports and driving safety',
      (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 11);

    expect(find.text('Need Help?'), findsOneWidget);
    expect(
      find.textContaining(
        'Settings > About & Support > Submit Feedback',
      ),
      findsOneWidget,
    );
    expect(
      find.textContaining('steps needed to reproduce it'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Uploading debug logs does not upload your coverage'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Only include debug logs when you experienced'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Do not operate the app while driving'),
      findsOneWidget,
    );
    expect(find.text('Finish Guide'), findsOneWidget);
  });

  for (final size in <Size>[const Size(390, 844), const Size(844, 390)]) {
    testWidgets('all pages fit at ${size.width.toInt()}x${size.height.toInt()}',
        (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(host());
      expect(tester.takeException(), isNull);

      for (var page = 1; page < 12; page++) {
        await tester.tap(find.text('Next'));
        await tester.pumpAndSettle();
        expect(find.text('Page ${page + 1} of 12'), findsOneWidget);
        expect(
          tester.takeException(),
          isNull,
          reason: 'page ${page + 1} overflowed at $size',
        );
      }
    });
  }
}

// The disclosure can be declined without accessing any platform services.
class _UnusedAppState extends ChangeNotifier implements AppStateProvider {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _CarpeaterAppState extends ChangeNotifier implements AppStateProvider {
  UserPreferences _preferences = const UserPreferences();

  @override
  UserPreferences get preferences => _preferences;

  @override
  bool get autoPingEnabled => false;

  @override
  List<Repeater> get repeaters => const [];

  @override
  void updatePreferences(UserPreferences preferences) {
    _preferences = preferences;
    notifyListeners();
  }

  @override
  String? repeaterNameForKey(String key) => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
