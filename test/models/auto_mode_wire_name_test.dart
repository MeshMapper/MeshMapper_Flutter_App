import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart';

/// The mode word the server reads on every session call and every queued
/// item. Trace is `trace` on the wire, never the enum name `targeted`.

void main() {
  test('each mode has its wire word', () {
    expect(AutoMode.active.wireName, 'active');
    expect(AutoMode.hybrid.wireName, 'hybrid');
    expect(AutoMode.passive.wireName, 'passive');
    expect(AutoMode.targeted.wireName, 'trace');
  });

  test('the wire words are the server enum and nothing else', () {
    final words = AutoMode.values.map((m) => m.wireName).toSet();
    expect(words, {'active', 'hybrid', 'passive', 'trace'});
    expect(words.contains('targeted'), isFalse);
  });
}
