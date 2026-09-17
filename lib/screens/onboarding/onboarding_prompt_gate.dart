import 'package:flutter/material.dart';

import '../../utils/debug_logger_io.dart';
import 'onboarding_guide_screen.dart';

class OnboardingPromptGate {
  bool _scheduled = false;
  bool _automaticAttemptClosed = false;

  bool shouldSchedule({
    required bool isMobile,
    required bool startupPromptsSettled,
    required bool stateLoaded,
    required bool isDue,
  }) =>
      isMobile && !_scheduled && startupPromptsSettled && stateLoaded && isDue;

  void markScheduled() {
    _scheduled = true;
  }

  bool reservesModalLane({
    required bool isMobile,
    required bool stateLoaded,
    required bool isDue,
  }) =>
      isMobile && !_automaticAttemptClosed && (!stateLoaded || isDue);

  void markAutomaticAttemptClosed() {
    _automaticAttemptClosed = true;
  }
}

typedef OnboardingGuideRoute = Future<OnboardingGuideResult?> Function(
  BuildContext,
  OnboardingGuideCompletion?,
);

/// Shared reservation for every automatic or manual guide presentation.
class OnboardingGuideCoordinator extends ChangeNotifier {
  /// Process-wide coordinator used by the app's guide presenters.
  static final shared = OnboardingGuideCoordinator();

  bool _isReserved = false;

  /// Whether a welcome prompt or guide route currently owns the modal lane.
  bool get isReserved => _isReserved;

  bool _reserve() {
    if (_isReserved) return false;
    _isReserved = true;
    notifyListeners();
    return true;
  }

  void _release() {
    if (!_isReserved) return;
    _isReserved = false;
    notifyListeners();
  }
}

typedef OnboardingWelcomePresenter = Future<bool?> Function(
  BuildContext,
  OnboardingGuideCompletion,
);

class OnboardingGuidePresenter {
  OnboardingGuidePresenter({
    OnboardingWelcomePresenter? showWelcome,
    OnboardingGuideRoute? showGuide,
    OnboardingGuideCoordinator? coordinator,
  })  : _showWelcome = showWelcome ?? _showDefaultWelcome,
        _showGuide = showGuide ?? _showDefaultGuide,
        coordinator = coordinator ?? OnboardingGuideCoordinator.shared;

  final OnboardingWelcomePresenter _showWelcome;
  final OnboardingGuideRoute _showGuide;

  /// Modal reservation shared with other guide presenters and MainScaffold.
  final OnboardingGuideCoordinator coordinator;

  Future<void> showAutomatic(
    BuildContext context, {
    required OnboardingGuideCompletion complete,
    required VoidCallback returnToMap,
  }) async {
    if (!coordinator._reserve()) return;
    try {
      final startGuide = await _showWelcome(context, complete);
      if (!context.mounted || startGuide == null) return;

      if (!startGuide) {
        returnToMap();
        return;
      }

      final result = await _showGuide(context, complete);
      if (!context.mounted || result == null) return;

      returnToMap();
    } finally {
      coordinator._release();
    }
  }

  Future<void> showManual(BuildContext context) async {
    if (!coordinator._reserve()) return;
    try {
      await _showGuide(context, null);
    } finally {
      coordinator._release();
    }
  }

  static Future<bool?> _showDefaultWelcome(
    BuildContext context,
    OnboardingGuideCompletion complete,
  ) {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => _OnboardingWelcomeDialog(
        complete: complete,
      ),
    );
  }

  static Future<OnboardingGuideResult?> _showDefaultGuide(
    BuildContext context,
    OnboardingGuideCompletion? complete,
  ) {
    return Navigator.of(context).push<OnboardingGuideResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => OnboardingGuideScreen(complete: complete),
      ),
    );
  }
}

class _OnboardingWelcomeDialog extends StatefulWidget {
  const _OnboardingWelcomeDialog({required this.complete});

  final OnboardingGuideCompletion complete;

  @override
  State<_OnboardingWelcomeDialog> createState() =>
      _OnboardingWelcomeDialogState();
}

class _OnboardingWelcomeDialogState extends State<_OnboardingWelcomeDialog> {
  var _completionInFlight = false;

  /// Persists the seen version, then closes the prompt with "do not start".
  ///
  /// [isDismiss] separates the two kinds of exit. Skip Guide is a deliberate
  /// answer, so a persist that fails keeps the prompt up and re-enables the
  /// button for another try. The back gesture is a dismiss and may never be a
  /// dead end: it attempts the same persist but closes either way, and the
  /// prompt simply comes back on the next launch. Both keep the in-flight
  /// guard, so a second tap or gesture during a persist is a no-op.
  Future<void> _skipGuide({bool isDismiss = false}) async {
    if (_completionInFlight) return;
    setState(() => _completionInFlight = true);

    final completed = await widget.complete();
    if (!mounted) return;
    if (completed) {
      Navigator.of(context).pop(false);
    } else if (isDismiss) {
      debugLog(
          '[APP] Onboarding seen version could not be saved, closing anyway');
      Navigator.of(context).pop(false);
    } else {
      setState(() => _completionInFlight = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Back runs the same persistence Skip does, so the prompt is not backed out
    // of without recording that it was seen. While a completion is in flight
    // the gesture does nothing, as before.
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _skipGuide(isDismiss: true);
      },
      child: AlertDialog(
        title: const Text('Welcome to MeshMapper'),
        content: const Text(
          "Take a quick tour before your first wardrive. We'll show you how "
          'to connect, what each mode does, how to use the map, and which '
          'settings keep coverage data accurate.\n\n'
          'You can skip now and open this guide anytime from Settings.',
        ),
        actions: [
          TextButton(
            onPressed: _completionInFlight ? null : _skipGuide,
            child: const Text('Skip Guide'),
          ),
          FilledButton(
            onPressed: _completionInFlight
                ? null
                : () => Navigator.of(context).pop(true),
            child: const Text('Start Guide'),
          ),
        ],
      ),
    );
  }
}
