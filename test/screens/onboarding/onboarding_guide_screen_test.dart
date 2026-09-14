import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';
import 'package:mesh_mapper/screens/onboarding/onboarding_guide_screen.dart';
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
      find.textContaining('Active Mode is disabled and hidden in most regions'),
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

  testWidgets('final page separates logs from coverage', (tester) async {
    await tester.pumpWidget(host());
    await goForward(tester, 11);

    expect(find.text('Just Choose a Mode and Drive'), findsOneWidget);
    expect(
      find.textContaining('Uploading Debug Logs does not upload your coverage'),
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
