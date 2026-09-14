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
