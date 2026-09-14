# MeshMapper First-Run Guide Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a versioned, one-time MeshMapper guide for all iOS and Android users in 1.4.0, with manual replay and the approved 12-page content.

**Architecture:** `AppStateProvider` owns an immutable guide-progress value and persists the seen version as a separate key in the existing `user_preferences` Hive box. `MainScaffold` sequences the welcome prompt after mandatory permissions, then opens a self-contained full-screen `PageView`. About & Support provides manual replay.

**Tech Stack:** Flutter, Dart, Material 3, Provider, Hive, flutter_test

**Spec:** `docs/superpowers/specs/2026-09-14-onboarding-guide-design.md`

## Global Constraints

- Current guide version is exactly `1`.
- Missing persisted state is version `0`, so new installs and existing upgrades see the guide.
- Automatic presentation is mobile-only. Do not show it in the retained web target.
- Skip and Finish persist version `1`; displaying or interrupting the guide does not.
- All state mutations and Hive writes go through `AppStateProvider`.
- The guide must not change connection, wardriving, upload, or debug-log state.
- Use the approved claims from the spec without changing their meaning.
- Use Material icons and Flutter-native illustrations, not screenshots or bitmap artwork.
- Keep every page scrollable and usable in portrait and landscape.
- All debug output must use a required tag such as `[APP]` or `[HIVE]`.
- Do not add packages.
- Never use em dash characters in copy, comments, documentation, or commits.
- Run `flutter analyze` after code edits.
- Keep architecture documentation in `AGENTS.md` and `DEVELOPMENT.md` synchronized.

## File Structure

- Create `lib/models/onboarding_guide_progress.dart` for pure version rules.
- Create `lib/screens/onboarding/onboarding_guide_screen.dart` for navigation and results.
- Create `lib/screens/onboarding/onboarding_guide_pages.dart` for approved content and native illustrations.
- Create `lib/screens/onboarding/onboarding_prompt_gate.dart` for one-shot startup scheduling.
- Create `lib/widgets/background_location_setup.dart` for the shared iOS permission action.
- Modify `lib/providers/app_state_provider.dart` for guide persistence.
- Modify `lib/screens/main_scaffold.dart` for automatic presentation and modal priority.
- Modify `lib/screens/settings/about_settings_page.dart` for manual replay.
- Modify `lib/screens/settings/general_settings_page.dart` to use the shared permission action.
- Add focused model and widget tests under `test/models/` and `test/screens/onboarding/`.
- Modify `AGENTS.md` and `DEVELOPMENT.md` with the same architecture note.

---

### Task 1: Versioned Guide Progress and Persistence

**Files:**
- Create: `lib/models/onboarding_guide_progress.dart`
- Modify: `lib/providers/app_state_provider.dart`
- Test: `test/models/onboarding_guide_progress_test.dart`

**Interfaces:**
- Produces: `OnboardingGuideProgress.currentVersion`, `fromStored(Object?)`, `isDue`, `isDueFor(int)`, and `completed()`.
- Produces: `AppStateProvider.onboardingGuideStateLoaded`, `shouldShowOnboardingGuide`, and `Future<bool> completeOnboardingGuide()`.
- Consumes: the existing `user_preferences` Hive box and `_openBoxSafely` recovery path.

- [ ] **Step 1: Write the failing pure progress test**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/onboarding_guide_progress.dart';

void main() {
  group('OnboardingGuideProgress', () {
    test('is not due before storage has loaded', () {
      expect(const OnboardingGuideProgress().isDue, isFalse);
    });

    test('missing storage makes guide version 1 due', () {
      final progress = OnboardingGuideProgress.fromStored(null);
      expect(progress.isLoaded, isTrue);
      expect(progress.seenVersion, 0);
      expect(progress.isDue, isTrue);
    });

    test('stored version 1 suppresses the current guide', () {
      expect(OnboardingGuideProgress.fromStored(1).isDue, isFalse);
    });

    test('invalid storage is version 0', () {
      expect(OnboardingGuideProgress.fromStored('1').seenVersion, 0);
      expect(OnboardingGuideProgress.fromStored(-4).seenVersion, 0);
    });

    test('a lower version is due after a version increase', () {
      expect(OnboardingGuideProgress.fromStored(1).isDueFor(2), isTrue);
    });

    test('completed advances to the current version', () {
      final progress = OnboardingGuideProgress.fromStored(null).completed();
      expect(progress.seenVersion, OnboardingGuideProgress.currentVersion);
      expect(progress.isDue, isFalse);
    });
  });
}
```

- [ ] **Step 2: Run the test and confirm it fails because the model is absent**

```bash
flutter test test/models/onboarding_guide_progress_test.dart
```

- [ ] **Step 3: Implement the immutable model**

```dart
import 'dart:math' as math;

class OnboardingGuideProgress {
  static const int currentVersion = 1;

  final int seenVersion;
  final bool isLoaded;

  const OnboardingGuideProgress({
    this.seenVersion = 0,
    this.isLoaded = false,
  });

  factory OnboardingGuideProgress.fromStored(Object? value) {
    final stored = value is int ? math.max(0, value) : 0;
    return OnboardingGuideProgress(seenVersion: stored, isLoaded: true);
  }

  bool get isDue => isDueFor(currentVersion);
  bool isDueFor(int version) => isLoaded && seenVersion < version;

  OnboardingGuideProgress completed() => const OnboardingGuideProgress(
        seenVersion: currentVersion,
        isLoaded: true,
      );
}
```

- [ ] **Step 4: Run the model test and confirm it passes**

```bash
flutter test test/models/onboarding_guide_progress_test.dart
```

- [ ] **Step 5: Add provider loading and persistence**

Import the model. Add these fields and getters near the preference-backed lifecycle state:

```dart
static const String _onboardingGuideVersionKey =
    'onboarding_guide_version_seen';

OnboardingGuideProgress _onboardingGuideProgress =
    const OnboardingGuideProgress();

bool get onboardingGuideStateLoaded => _onboardingGuideProgress.isLoaded;
bool get shouldShowOnboardingGuide => _onboardingGuideProgress.isDue;
```

In `_loadPreferences()`, load `box.get(_onboardingGuideVersionKey)` through `OnboardingGuideProgress.fromStored`. The `box == null` path must call `fromStored(null)` before setting `_preferencesLoaded`. If preference parsing throws before guide state has loaded, also call `fromStored(null)` in the catch path.

Add this provider method. Persist before changing memory so a failed write leaves the guide due:

```dart
Future<bool> completeOnboardingGuide() async {
  final box = await _openBoxSafely(_preferencesBoxName);
  if (box == null) return false;
  try {
    await box.put(
      _onboardingGuideVersionKey,
      OnboardingGuideProgress.currentVersion,
    );
    _onboardingGuideProgress = _onboardingGuideProgress.completed();
    debugLog('[APP] Onboarding guide completed');
    notifyListeners();
    return true;
  } catch (e) {
    debugError('[APP] Failed to persist onboarding guide completion: $e');
    return false;
  }
}
```

Use plain `notifyListeners()` because guide state is not map-rendered state.

- [ ] **Step 6: Format, analyze, and run the focused test**

```bash
dart format lib/models/onboarding_guide_progress.dart lib/providers/app_state_provider.dart test/models/onboarding_guide_progress_test.dart
flutter test test/models/onboarding_guide_progress_test.dart
flutter analyze
```

- [ ] **Step 7: Commit the state task**

```bash
git add lib/models/onboarding_guide_progress.dart lib/providers/app_state_provider.dart test/models/onboarding_guide_progress_test.dart
git commit -m "Remember the quick guide"
```

---

### Task 2: Full-Screen Guide and Approved Content

**Files:**
- Create: `lib/screens/onboarding/onboarding_guide_screen.dart`
- Create: `lib/screens/onboarding/onboarding_guide_pages.dart`
- Create: `lib/widgets/background_location_setup.dart`
- Modify: `lib/screens/settings/general_settings_page.dart`
- Test: `test/screens/onboarding/onboarding_guide_screen_test.dart`

**Interfaces:**
- Produces: `enum OnboardingGuideResult { skipped, finished }`.
- Produces: `const OnboardingGuideScreen()`.
- Produces: `Future<bool> setUpBackgroundLocation(BuildContext, AppStateProvider)`.
- Consumes: `AppStateProvider.requestAlwaysLocationPermission()` for the iPhone-only action.

- [ ] **Step 1: Write failing widget tests for navigation, platform copy, and the final warning**

Use this host and add tests for Page 1, Next, Back, Skip, Finish, Android background copy, iPhone setup action, all required claims, and both orientations:

```dart
Widget host({TargetPlatform platform = TargetPlatform.android}) {
  return MaterialApp(
    theme: ThemeData(platform: platform, useMaterial3: true),
    home: const OnboardingGuideScreen(),
  );
}

testWidgets('shows the approved first page and progress', (tester) async {
  await tester.pumpWidget(host());
  expect(find.text('Connect Your MeshCore Radio'), findsOneWidget);
  expect(find.text('Page 1 of 12'), findsOneWidget);
  expect(find.text('Skip Guide'), findsOneWidget);
});

testWidgets('Android needs no extra background permission', (tester) async {
  await tester.pumpWidget(host());
  for (var i = 0; i < 6; i++) {
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }
  expect(
    find.textContaining(
      'No additional background location permission is required',
    ),
    findsOneWidget,
  );
  expect(find.text('Set Up Background Location'), findsNothing);
});

testWidgets('final page separates logs from coverage', (tester) async {
  await tester.pumpWidget(host());
  for (var i = 0; i < 11; i++) {
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
  }
  expect(find.text('Just Choose a Mode and Drive'), findsOneWidget);
  expect(
    find.textContaining('Uploading Debug Logs does not upload your coverage'),
    findsOneWidget,
  );
  expect(find.text('Finish Guide'), findsOneWidget);
});
```

Push the screen from a Builder in the Skip and Finish tests and assert the returned `OnboardingGuideResult`. Set the surface to `Size(390, 844)` and `Size(844, 390)`, visit all 12 pages, and assert `tester.takeException()` is null.

- [ ] **Step 2: Run the guide test and confirm the screen is absent**

```bash
flutter test test/screens/onboarding/onboarding_guide_screen_test.dart
```

- [ ] **Step 3: Extract the shared iPhone background setup action**

Create `lib/widgets/background_location_setup.dart` with `setUpBackgroundLocation`. It must show `PermissionDisclosureService.showBackgroundLocationDisclosure`, return immediately on decline, call `appState.requestAlwaysLocationPermission`, and show a dialog with Not Now and Open Settings when Always permission is not granted. Open Settings with `Geolocator.openAppSettings()`.

Update `_BackgroundModeToggle._requestPermission()` in `general_settings_page.dart` to call the shared function and then refresh `_hasAlwaysPermission`. Delete only its duplicated request and permission-denied code. Keep the separate disable flow unchanged.

- [ ] **Step 4: Implement the guide navigation shell**

The public contract is:

```dart
enum OnboardingGuideResult { skipped, finished }

class OnboardingGuideScreen extends StatefulWidget {
  const OnboardingGuideScreen({super.key});

  @override
  State<OnboardingGuideScreen> createState() =>
      _OnboardingGuideScreenState();
}
```

The state owns a `PageController` and index. Build a Scaffold with Close, `Page X of 12`, persistent Skip Guide, a linear progress indicator, an expanded PageView, and a bottom navigation row. Back is hidden on page 1. Next uses a 220 ms ease-out animation. Finish Guide returns `OnboardingGuideResult.finished`; Skip returns `OnboardingGuideResult.skipped`; Close returns null. Dispose the controller.

- [ ] **Step 5: Implement the reusable page shell and all 12 pages**

In `onboarding_guide_pages.dart`, create a scrollable `OnboardingGuidePage` constrained to 620 logical pixels, plus reusable paragraph, bullet, callout, comparison, and icon-row widgets.

Build pages in this exact order:

```dart
List<Widget> buildOnboardingGuidePages(BuildContext context) => [
  buildConnectPage(context),
  buildAntennaPage(context),
  buildModesPage(context),
  buildMapControlsPage(context),
  buildSmartPingingPage(context),
  buildCarpeaterPage(context),
  buildBackgroundPage(context),
  buildResultsPage(context),
  buildOnlineOfflinePage(context),
  buildPrivacyPage(context),
  buildAccountPage(context),
  buildAutomaticUploadsPage(context),
];
```

Copy every heading, claim, warning, and navigation path from spec pages 1 through 12. Do not shorten the regional Active Mode rule, Android permission statement, CARpeater pass-through explanation, account proof, or final debug-log warning.

Use `Theme.of(context).platform == TargetPlatform.iOS` for the background page. Only iPhone shows Set Up Background Location. That button calls the shared setup function through `context.read<AppStateProvider>()`.

Build the illustrations from themed Containers and Material icons:

- Connect: highlighted Connect tab, radio row, green Connected chip.
- Antenna: inside-vehicle and exposed-placement comparison cards.
- Modes: four mode cards, with Passive emphasized.
- Map controls: real toolbar icons in current order with labels.
- Smart Pinging: three map squares joined by arrows.
- CARpeater: vehicle containing radio and repeater, with a fixed tower outside.
- Background: phone and lock with Android notification or iPhone Always badge.
- Results: real `PingColors` swatches for BIDIR, DISC, TX, RX, DEAD, and DROP.
- Online/offline: server cloud beside local phone storage.
- Privacy: server, radio broadcast, anonymous account, and safety icons.
- Account: signed challenge, linked radio, and claimed tower.
- Uploads: green automatic coverage path separated from orange support logs.

- [ ] **Step 6: Run and extend the guide tests**

Add `find.textContaining` assertions for these exact fragments:

- `Active Mode is disabled and hidden in most regions`
- `Regional administrators may require Smart Pinging`
- `If your CARpeater is not reported`
- `cryptographically sign a challenge`
- `Uploading Debug Logs does not upload your coverage`

Run:

```bash
dart format lib/screens/onboarding lib/widgets/background_location_setup.dart lib/screens/settings/general_settings_page.dart test/screens/onboarding/onboarding_guide_screen_test.dart
flutter test test/screens/onboarding/onboarding_guide_screen_test.dart
flutter analyze
```

- [ ] **Step 7: Commit the guide task**

```bash
git add lib/screens/onboarding lib/widgets/background_location_setup.dart lib/screens/settings/general_settings_page.dart test/screens/onboarding/onboarding_guide_screen_test.dart
git commit -m "Add the MeshMapper quick guide"
```

---

### Task 3: Startup Prompt, Modal Priority, and Settings Replay

**Files:**
- Create: `lib/screens/onboarding/onboarding_prompt_gate.dart`
- Modify: `lib/screens/main_scaffold.dart`
- Modify: `lib/screens/settings/about_settings_page.dart`
- Test: `test/screens/onboarding/onboarding_prompt_gate_test.dart`

**Interfaces:**
- Consumes: provider guide getters and completion method from Task 1.
- Consumes: screen and result enum from Task 2.
- Produces: `OnboardingPromptGate.shouldSchedule(...)`, one automatic presentation per process, and the Quick Guide Settings row.

- [ ] **Step 1: Write the failing prompt-gate truth table**

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/screens/onboarding/onboarding_prompt_gate.dart';

void main() {
  test('waits for startup prompts and persisted state', () {
    final gate = OnboardingPromptGate();
    expect(gate.shouldSchedule(
      isMobile: true,
      startupPromptsSettled: false,
      stateLoaded: true,
      isDue: true,
    ), isFalse);
    expect(gate.shouldSchedule(
      isMobile: true,
      startupPromptsSettled: true,
      stateLoaded: false,
      isDue: true,
    ), isFalse);
  });

  test('schedules only once when ready and due', () {
    final gate = OnboardingPromptGate();
    expect(gate.shouldSchedule(
      isMobile: true,
      startupPromptsSettled: true,
      stateLoaded: true,
      isDue: true,
    ), isTrue);
    gate.markScheduled();
    expect(gate.shouldSchedule(
      isMobile: true,
      startupPromptsSettled: true,
      stateLoaded: true,
      isDue: true,
    ), isFalse);
  });

  test('never schedules on web or after completion', () {
    final gate = OnboardingPromptGate();
    expect(gate.shouldSchedule(
      isMobile: false,
      startupPromptsSettled: true,
      stateLoaded: true,
      isDue: true,
    ), isFalse);
    expect(gate.shouldSchedule(
      isMobile: true,
      startupPromptsSettled: true,
      stateLoaded: true,
      isDue: false,
    ), isFalse);
  });
}
```

- [ ] **Step 2: Run the test and confirm the gate is absent**

```bash
flutter test test/screens/onboarding/onboarding_prompt_gate_test.dart
```

- [ ] **Step 3: Implement the one-shot gate**

```dart
class OnboardingPromptGate {
  bool _scheduled = false;

  bool shouldSchedule({
    required bool isMobile,
    required bool startupPromptsSettled,
    required bool stateLoaded,
    required bool isDue,
  }) => isMobile &&
      !_scheduled &&
      startupPromptsSettled &&
      stateLoaded &&
      isDue;

  void markScheduled() {
    _scheduled = true;
  }
}
```

- [ ] **Step 4: Sequence the automatic guide in MainScaffold**

Add `_onboardingGate`, `_startupPromptsSettled`, and `_onboardingGuideOpen` fields. Set `_startupPromptsSettled` in a `finally` block around `_checkAndShowDisclosure` so it becomes true after the existing iOS, Android, or web permission path settles.

In `build()`, schedule only when this expression is true:

```dart
_onboardingGate.shouldSchedule(
  isMobile: !kIsWeb,
  startupPromptsSettled: _startupPromptsSettled,
  stateLoaded: appState.onboardingGuideStateLoaded,
  isDue: appState.shouldShowOnboardingGuide,
)
```

Call `markScheduled()` and set `_onboardingGuideOpen = true` before the post-frame callback. Show the exact welcome dialog from the spec with Skip Guide and Start Guide. Skip calls `completeOnboardingGuide`. Start pushes `const OnboardingGuideScreen()`. A skipped or finished result calls `completeOnboardingGuide`; a null result does not. After a non-null result, set `_selectedIndex = 0`. Clear `_onboardingGuideOpen` in `finally`.

Add `!_onboardingGuideOpen` to the account-link and CARpeater prompt conditions. Reserve the global modal lane while automatic onboarding is due but still waiting to open, so another prompt cannot appear first.

- [ ] **Step 5: Add manual replay to About & Support**

At the top of the Support card, add:

```dart
ListTile(
  leading: const Icon(Icons.help_outline),
  title: const Text('Quick Guide'),
  subtitle: const Text('Learn connections, modes, mapping, and data'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => const OnboardingGuideScreen(),
    ),
  ),
),
```

Manual replay must not read or write the seen version. Close, Skip, and Finish all return to About & Support.

- [ ] **Step 6: Format and verify integration**

```bash
dart format lib/screens/main_scaffold.dart lib/screens/settings/about_settings_page.dart lib/screens/onboarding/onboarding_prompt_gate.dart test/screens/onboarding/onboarding_prompt_gate_test.dart
flutter test test/screens/onboarding/onboarding_prompt_gate_test.dart
flutter test test/screens/onboarding/onboarding_guide_screen_test.dart
flutter test test/models/onboarding_guide_progress_test.dart
flutter analyze
```

- [ ] **Step 7: Commit the integration task**

```bash
git add lib/screens/main_scaffold.dart lib/screens/settings/about_settings_page.dart lib/screens/onboarding/onboarding_prompt_gate.dart test/screens/onboarding/onboarding_prompt_gate_test.dart
git commit -m "Show the quick guide once"
```

---

### Task 4: Documentation, Full Verification, and Integration

**Files:**
- Modify: `AGENTS.md`
- Modify: `DEVELOPMENT.md`
- Review: all files changed by Tasks 1 through 3

**Interfaces:**
- Consumes: the complete onboarding feature.
- Produces: synchronized documentation and a verified branch ready for `dev`.

- [ ] **Step 1: Add the same architecture section to both guides**

```markdown
### First-Run Quick Guide

The iOS and Android apps show a versioned Quick Guide after the required
first-run permission flow. `AppStateProvider` owns the seen-version state and
stores it as a separate key in the `user_preferences` Hive box, so a missing
key makes the current guide due for both new installs and existing upgrades.
Skip and Finish persist completion; simply opening or interrupting the guide
does not. `MainScaffold` serializes the welcome prompt with other global
dialogs, and About & Support always offers manual replay. The guide is a
self-contained Flutter PageView and never changes connection, wardriving, or
upload state.
```

- [ ] **Step 2: Check copy and repository rules**

```bash
git diff --unified=0 -- lib/screens/onboarding lib/widgets/background_location_setup.dart test/screens/onboarding AGENTS.md DEVELOPMENT.md | rg '^\\+.*(\\x{2014}|\\x{2013})'
rg -n "Uploading Debug Logs does not upload your coverage|Active Mode is disabled and hidden in most regions|No additional background location permission is required" lib/screens/onboarding
git diff --check
```

The first command must have no output. The required phrases must all be found. `git diff --check` must succeed.

- [ ] **Step 3: Run focused and full verification**

```bash
flutter test test/models/onboarding_guide_progress_test.dart test/screens/onboarding/onboarding_prompt_gate_test.dart test/screens/onboarding/onboarding_guide_screen_test.dart
flutter analyze
flutter test
```

- [ ] **Step 4: Review the final diff against the approved spec**

Confirm every item:

- Automatic guide is mobile-only and waits for permission handling.
- Existing users without the new key see version 1.
- Skip and Finish persist, while Close and interruption do not.
- Global dialogs cannot stack over automatic onboarding.
- Android has no background setup action.
- iPhone setup reuses the existing disclosure.
- All 12 pages use approved claims and render in both orientations.
- Manual replay changes no app or session state.
- Coverage uploads and support logs are unmistakably different.
- No package, bitmap, secret, or unrelated refactor was added.

- [ ] **Step 5: Commit synchronized documentation**

```bash
git add AGENTS.md DEVELOPMENT.md
git commit -m "Document the quick guide flow"
```

- [ ] **Step 6: Merge the reviewed branch into dev and push**

```bash
git switch dev
git merge --no-ff onboarding-guide
git log --oneline origin/dev..dev
git push origin dev
```

Do not include unrelated untracked files in any commit.
