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
