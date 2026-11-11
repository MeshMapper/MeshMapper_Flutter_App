import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// The Go Online refusal outside every zone. It used to read "Could not
/// determine your zone. Check GPS and internet connection." even when the
/// server had answered plainly that the spot was 28 km outside the nearest
/// zone, so one tester retried 11 times. The check now runs before
/// wardriving stops, so the message also says Offline Mode stays on.
void main() {
  test('names the nearest zone and its distance', () {
    expect(
      goOnlineOutsideZoneMessage(
          {'name': 'Greater Montana, US', 'code': 'FCA', 'distance_km': 27.97}),
      'You are outside every MeshMapper zone. Nearest zone is '
      'Greater Montana, US, 28.0km away. Offline Mode stays on.',
    );
  });

  test('uses miles for imperial units', () {
    expect(
      goOnlineOutsideZoneMessage(
          {'name': 'Greater Montana, US', 'distance_km': 27.97},
          isImperial: true),
      contains('17.4mi away'),
    );
  });

  test('without a nearest zone it still says what happened', () {
    const plain =
        'You are outside every MeshMapper zone. Offline Mode stays on.';
    expect(goOnlineOutsideZoneMessage(null), plain);
    expect(goOnlineOutsideZoneMessage({'name': 'Greater Montana, US'}), plain);
  });
}
