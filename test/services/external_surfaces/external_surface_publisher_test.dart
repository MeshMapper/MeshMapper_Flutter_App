import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/external_surfaces/external_surface_publisher.dart';

void main() {
  test('a held update is reported once per floor window', () async {
    const floor = Duration(milliseconds: 300);
    final published = <String>[];
    final held = <Duration>[];
    final publisher = ExternalSurfacePublisher<String, String>(
      debounceDelay: const Duration(milliseconds: 1),
      minimumNonUrgentInterval: floor,
      isEnabled: () => true,
      preflightPolicy: ExternalSurfacePreflightPolicy.throttleAgainstLastBuild,
      payloadBuilder: (snapshot) => snapshot,
      fingerprintBuilder: (payload) => payload,
      urgencyKeyBuilder: (_) => 'steady',
      publish: (publication) async {
        published.add(publication.payload);
        return const ExternalSurfacePublishResult.published();
      },
      onHeld: held.add,
    );
    addTearDown(publisher.dispose);

    var snapshot = '';
    void schedule(String next, {bool immediate = false}) {
      snapshot = next;
      publisher.schedule(
        () => snapshot,
        preflightKeyBuilder: () => 'steady',
        immediate: immediate,
      );
    }

    schedule('a', immediate: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(published, ['a']);

    // Three ordinary notifies inside the window: every one re-arms the floor
    // timer, which is exactly why a per-call line would be spam.
    for (final next in ['b', 'c', 'd']) {
      schedule(next);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect(published, ['a'], reason: 'nothing urgent changed, the floor holds');
    expect(held.length, 1,
        reason: 'one report per held window, not per re-arm');
    expect(held.single, lessThanOrEqualTo(floor));

    await Future<void>.delayed(floor + const Duration(milliseconds: 150));
    expect(published, ['a', 'd'],
        reason: 'the held update lands with the latest state once the floor '
            'has passed');

    schedule('e');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(held.length, 2,
        reason: 'a publish closes the window, so the next hold reports again');
  });
}
