import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/path_hash_mode_policy.dart';

void main() {
  test('same enforced policy keeps the current radio width', () {
    final policy = resolvePathHashModePolicy(
      deviceHopBytes: 1,
      currentRuntimeHopBytes: 3,
      enforcedHopBytes: 3,
      enforceHopBytes: true,
    );

    expect(policy.desiredHopBytes, 3);
    expect(policy.needsRadioWrite, isFalse);
  });

  test('removing enforcement restores the device firmware width', () {
    final policy = resolvePathHashModePolicy(
      deviceHopBytes: 1,
      currentRuntimeHopBytes: 3,
      enforcedHopBytes: 3,
      enforceHopBytes: false,
    );

    expect(policy.desiredHopBytes, 1);
    expect(policy.needsRadioWrite, isTrue);
  });
}
