import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';

/// The wire values are a contract with Swift, which matches on these strings
/// in MeshMapperLiveActivity.swift. A rename here fails no Swift build, so
/// pin the ones the native side switches on.
void main() {
  test('deferred and skipped keep the wire strings Swift matches on', () {
    expect(LiveActivityPhase.deferred.wireValue, 'deferred');
    expect(LiveActivityPhase.skipped.wireValue, 'skipped');
  });

  test('every phase has a unique, non-empty wire value', () {
    final values = LiveActivityPhase.values.map((p) => p.wireValue).toList();
    expect(values.where((v) => v.isEmpty), isEmpty);
    expect(values.toSet().length, values.length,
        reason: 'two phases sharing a wire value would collide in Swift');
  });
}
