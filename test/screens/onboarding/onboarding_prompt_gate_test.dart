import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/screens/onboarding/onboarding_guide_screen.dart';
import 'package:mesh_mapper/screens/onboarding/onboarding_prompt_gate.dart';

void main() {
  test('waits for startup prompts and persisted state', () {
    final gate = OnboardingPromptGate();
    expect(
      gate.shouldSchedule(
        isMobile: true,
        startupPromptsSettled: false,
        stateLoaded: true,
        isDue: true,
      ),
      isFalse,
    );
    expect(
      gate.shouldSchedule(
        isMobile: true,
        startupPromptsSettled: true,
        stateLoaded: false,
        isDue: true,
      ),
      isFalse,
    );
  });

  test('schedules only once when ready and due', () {
    final gate = OnboardingPromptGate();
    expect(
      gate.shouldSchedule(
        isMobile: true,
        startupPromptsSettled: true,
        stateLoaded: true,
        isDue: true,
      ),
      isTrue,
    );
    gate.markScheduled();
    expect(
      gate.shouldSchedule(
        isMobile: true,
        startupPromptsSettled: true,
        stateLoaded: true,
        isDue: true,
      ),
      isFalse,
    );
  });

  test('never schedules on web or after completion', () {
    final gate = OnboardingPromptGate();
    expect(
      gate.shouldSchedule(
        isMobile: false,
        startupPromptsSettled: true,
        stateLoaded: true,
        isDue: true,
      ),
      isFalse,
    );
    expect(
      gate.shouldSchedule(
        isMobile: true,
        startupPromptsSettled: true,
        stateLoaded: true,
        isDue: false,
      ),
      isFalse,
    );
  });

  testWidgets('reserves the modal lane through loading and one presentation',
      (tester) async {
    final gate = OnboardingPromptGate();
    var stateLoaded = false;
    var startupPromptsSettled = false;
    var schedules = 0;

    Widget buildHarness() => MaterialApp(
          home: StatefulBuilder(
            builder: (context, setState) {
              if (gate.shouldSchedule(
                isMobile: true,
                startupPromptsSettled: startupPromptsSettled,
                stateLoaded: stateLoaded,
                isDue: true,
              )) {
                gate.markScheduled();
                schedules++;
              }
              final reserved = gate.reservesModalLane(
                isMobile: true,
                stateLoaded: stateLoaded,
                isDue: true,
              );
              return Scaffold(
                body: Text(reserved ? 'Guide lane held' : 'Account allowed'),
              );
            },
          ),
        );

    await tester.pumpWidget(buildHarness());
    expect(find.text('Guide lane held'), findsOneWidget);
    expect(schedules, 0);

    await tester.pumpWidget(buildHarness());
    expect(schedules, 0);

    stateLoaded = true;
    startupPromptsSettled = true;
    await tester.pumpWidget(buildHarness());
    expect(find.text('Guide lane held'), findsOneWidget);
    expect(schedules, 1);

    await tester.pumpWidget(buildHarness());
    expect(schedules, 1);

    gate.markAutomaticAttemptClosed();
    await tester.pumpWidget(buildHarness());
    expect(find.text('Account allowed'), findsOneWidget);
  });

  testWidgets('automatic completion returns to Map', (tester) async {
    var completions = 0;
    final presenter = OnboardingGuidePresenter(
      showWelcome: (_, __) async => true,
      showGuide: (_, complete) async {
        await complete!();
        return OnboardingGuideResult.finished;
      },
    );

    await tester.pumpWidget(_PresentationHarness(
      presenter: presenter,
      complete: () async {
        completions++;
        return true;
      },
    ));

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();

    expect(completions, 1);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('a dismissed automatic guide stays incomplete', (tester) async {
    var completions = 0;
    final presenter = OnboardingGuidePresenter(
      showWelcome: (_, __) async => true,
      showGuide: (_, __) async => null,
    );

    await tester.pumpWidget(_PresentationHarness(
      presenter: presenter,
      complete: () async {
        completions++;
        return true;
      },
    ));

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();

    expect(completions, 0);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('manual replay leaves completion state unchanged',
      (tester) async {
    var completions = 0;
    final presenter = OnboardingGuidePresenter(
      showWelcome: (_, __) async => false,
      showGuide: (_, __) async => OnboardingGuideResult.skipped,
    );

    await tester.pumpWidget(_PresentationHarness(
      presenter: presenter,
      complete: () async {
        completions++;
        return true;
      },
    ));

    await tester.tap(find.text('Replay guide'));
    await tester.pumpAndSettle();

    expect(completions, 0);
    expect(find.text('Settings'), findsOneWidget);
  });

  testWidgets('manual replay holds a pending competing prompt until close',
      (tester) async {
    final coordinator = OnboardingGuideCoordinator();
    final harnessKey = GlobalKey<_ManualCoordinationHarnessState>();

    await tester.pumpWidget(
      MaterialApp(
        home: _ManualCoordinationHarness(
          key: harnessKey,
          coordinator: coordinator,
        ),
      ),
    );

    await tester.tap(find.text('Replay guide'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1 of 12'), findsOneWidget);

    harnessKey.currentState!.markCompetingPromptPending();
    await tester.pump();
    expect(find.text('Competing prompt'), findsNothing);

    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Competing prompt'), findsOneWidget);
  });

  testWidgets('welcome Skip waits for completion persistence', (tester) async {
    final persistence = Completer<bool>();
    var completions = 0;

    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () {
          completions++;
          return persistence.future;
        },
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip Guide'));
    await tester.pump();

    expect(completions, 1);
    expect(find.text('Welcome to MeshMapper'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Skip Guide'))
            .onPressed,
        isNull);

    persistence.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('Welcome to MeshMapper'), findsNothing);
    expect(find.text('Map'), findsOneWidget);
  });

  for (final succeeds in [true, false]) {
    testWidgets(
        'welcome blocks Back during Skip then handles success=$succeeds',
        (tester) async {
      final persistence = Completer<bool>();
      final presenter = _freshPresenter();
      await tester.pumpWidget(_PresentationHarness(
        presenter: presenter,
        complete: () => persistence.future,
      ));
      await tester.tap(find.text('Show automatic guide'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Skip Guide'));
      await tester.pump();

      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Welcome to MeshMapper'), findsOneWidget);
      expect(presenter.coordinator.isReserved, isTrue);

      persistence.complete(succeeds);
      await tester.pumpAndSettle();
      if (succeeds) {
        expect(find.text('Welcome to MeshMapper'), findsNothing);
        expect(find.text('Map'), findsOneWidget);
      } else {
        expect(find.text('Welcome to MeshMapper'), findsOneWidget);
        expect(
          tester
              .widget<TextButton>(
                find.widgetWithText(TextButton, 'Skip Guide'),
              )
              .onPressed,
          isNotNull,
        );
        // Back is a dismiss: it attempts the same persist and then closes even
        // though it failed again, so the gesture is never a dead end.
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(find.text('Welcome to MeshMapper'), findsNothing);
        expect(find.text('Map'), findsOneWidget);
      }
      expect(presenter.coordinator.isReserved, isFalse);
    });
  }

  testWidgets('welcome Back persists the seen version like Skip',
      (tester) async {
    var completions = 0;
    await tester.pumpWidget(_PresentationHarness(
      presenter: _freshPresenter(),
      complete: () async {
        completions++;
        return true;
      },
    ));
    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Welcome to MeshMapper'), findsNothing);
    // Backing out used to dismiss the prompt without recording it, so the
    // welcome dialog came back on the next launch.
    expect(completions, 1);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('guide Close persists the seen version like Skip',
      (tester) async {
    final persistence = Completer<bool>();
    var completions = 0;

    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () {
          completions++;
          return persistence.future;
        },
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();

    // The X used to pop with no result and no persistence, so the welcome
    // dialog came back on the next launch.
    expect(completions, 1);
    expect(find.text('Page 1 of 12'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.close))
          .onPressed,
      isNull,
    );

    persistence.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('Page 1 of 12'), findsNothing);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('guide Back persists the seen version like Skip',
      (tester) async {
    final persistence = Completer<bool>();
    var completions = 0;

    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () {
          completions++;
          return persistence.future;
        },
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Guide'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1 of 12'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    // Back used to pop the guide with no result and no persistence, so the
    // welcome dialog came back on the next launch.
    expect(completions, 1);
    expect(find.text('Page 1 of 12'), findsOneWidget);

    // A second Back while the first is still persisting is a no-op.
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(completions, 1);
    expect(find.text('Page 1 of 12'), findsOneWidget);

    persistence.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('Page 1 of 12'), findsNothing);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('guide Skip waits for completion persistence', (tester) async {
    final persistence = Completer<bool>();
    var completions = 0;

    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () {
          completions++;
          return persistence.future;
        },
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip Guide'));
    await tester.pump();

    expect(completions, 1);
    expect(find.text('Page 1 of 12'), findsOneWidget);
    expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, 'Skip Guide'))
            .onPressed,
        isNull);

    persistence.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('Page 1 of 12'), findsNothing);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('guide Finish waits for completion persistence', (tester) async {
    final persistence = Completer<bool>();

    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () => persistence.future,
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Guide'));
    await tester.pumpAndSettle();
    await _goToFinalPage(tester);
    await tester.tap(find.text('Finish Guide'));
    await tester.pump();

    expect(find.text('Page 12 of 12'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Finish Guide'),
          )
          .onPressed,
      isNull,
    );

    persistence.complete(true);
    await tester.pumpAndSettle();

    expect(find.text('Page 12 of 12'), findsNothing);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('failed persistence keeps the welcome prompt open',
      (tester) async {
    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () async => false,
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip Guide'));
    await tester.pumpAndSettle();

    expect(find.text('Welcome to MeshMapper'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, 'Skip Guide'))
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('failed persistence keeps the guide open', (tester) async {
    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () async => false,
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Skip Guide'));
    await tester.pumpAndSettle();

    expect(find.text('Page 1 of 12'), findsOneWidget);
    expect(
      tester
          .widget<TextButton>(
            find.widgetWithText(TextButton, 'Skip Guide'),
          )
          .onPressed,
      isNotNull,
    );
  });

  testWidgets('failed persistence still lets the guide Close out',
      (tester) async {
    var completions = 0;
    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () async {
          completions++;
          return false;
        },
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Guide'));
    await tester.pumpAndSettle();

    // Skip Guide is a deliberate completion, so it refuses to close.
    await tester.tap(find.text('Skip Guide'));
    await tester.pumpAndSettle();
    expect(completions, 1);
    expect(find.text('Page 1 of 12'), findsOneWidget);

    // The X is a dismiss: it attempts the same persist and closes anyway, so
    // a broken write can never trap the user in the guide.
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(completions, 2);
    expect(find.text('Page 1 of 12'), findsNothing);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('failed persistence still lets the guide Back out',
      (tester) async {
    var completions = 0;
    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () async {
          completions++;
          return false;
        },
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start Guide'));
    await tester.pumpAndSettle();
    expect(find.text('Page 1 of 12'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(completions, 1);
    expect(find.text('Page 1 of 12'), findsNothing);
    expect(find.text('Map'), findsOneWidget);
  });

  testWidgets('failed persistence still lets the welcome prompt Back out',
      (tester) async {
    var completions = 0;
    await tester.pumpWidget(
      _PresentationHarness(
        presenter: _freshPresenter(),
        complete: () async {
          completions++;
          return false;
        },
      ),
    );

    await tester.tap(find.text('Show automatic guide'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to MeshMapper'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();

    expect(completions, 1);
    expect(find.text('Welcome to MeshMapper'), findsNothing);
    expect(find.text('Map'), findsOneWidget);
  });
}

Future<void> _goToFinalPage(WidgetTester tester) async {
  for (var page = 1; page < 12; page++) {
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }
}

OnboardingGuidePresenter _freshPresenter() => OnboardingGuidePresenter(
      coordinator: OnboardingGuideCoordinator(),
    );

class _PresentationHarness extends StatefulWidget {
  const _PresentationHarness({required this.presenter, required this.complete});

  final OnboardingGuidePresenter presenter;
  final Future<bool> Function() complete;

  @override
  State<_PresentationHarness> createState() => _PresentationHarnessState();
}

class _ManualCoordinationHarness extends StatefulWidget {
  const _ManualCoordinationHarness({
    super.key,
    required this.coordinator,
  });

  final OnboardingGuideCoordinator coordinator;

  @override
  State<_ManualCoordinationHarness> createState() =>
      _ManualCoordinationHarnessState();
}

class _ManualCoordinationHarnessState
    extends State<_ManualCoordinationHarness> {
  late final OnboardingGuidePresenter _presenter;
  var _competingPromptPending = false;
  var _competingPromptOpen = false;

  @override
  void initState() {
    super.initState();
    _presenter = OnboardingGuidePresenter(coordinator: widget.coordinator);
    widget.coordinator.addListener(_onCoordinatorChanged);
  }

  @override
  void dispose() {
    widget.coordinator.removeListener(_onCoordinatorChanged);
    super.dispose();
  }

  void _onCoordinatorChanged() {
    if (mounted) setState(() {});
  }

  void markCompetingPromptPending() {
    setState(() => _competingPromptPending = true);
  }

  @override
  Widget build(BuildContext context) {
    if (_competingPromptPending &&
        !widget.coordinator.isReserved &&
        !_competingPromptOpen) {
      _competingPromptOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => const AlertDialog(
            title: Text('Competing prompt'),
          ),
        );
      });
    }

    return Scaffold(
      body: TextButton(
        onPressed: () => _presenter.showManual(context),
        child: const Text('Replay guide'),
      ),
    );
  }
}

class _PresentationHarnessState extends State<_PresentationHarness> {
  var _tab = 'Settings';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Column(
            children: [
              Text(_tab),
              TextButton(
                onPressed: () async {
                  await widget.presenter.showAutomatic(
                    context,
                    complete: widget.complete,
                    returnToMap: () => setState(() => _tab = 'Map'),
                  );
                },
                child: const Text('Show automatic guide'),
              ),
              TextButton(
                onPressed: () => widget.presenter.showManual(context),
                child: const Text('Replay guide'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
