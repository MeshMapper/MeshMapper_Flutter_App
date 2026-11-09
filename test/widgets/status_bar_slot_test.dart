import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/widgets/status_bar.dart';

void main() {
  group('statusBarSharedSlot', () {
    test('Trace mode shows Trace', () {
      expect(
          statusBarSharedSlot(
              targetedMode: true, scopeDiscoveryOn: false, scopeCount: 0),
          StatusBarSlot.trace);
    });

    test('Trace mode wins even with scope discovery on and scopes counted', () {
      expect(
          statusBarSharedSlot(
              targetedMode: true, scopeDiscoveryOn: true, scopeCount: 12),
          StatusBarSlot.trace);
    });

    test('scope discovery on shows Scope, even before the first answer', () {
      expect(
          statusBarSharedSlot(
              targetedMode: false, scopeDiscoveryOn: true, scopeCount: 0),
          StatusBarSlot.scope);
    });

    test('scopes counted this session keep Scope after it is turned off', () {
      expect(
          statusBarSharedSlot(
              targetedMode: false, scopeDiscoveryOn: false, scopeCount: 3),
          StatusBarSlot.scope);
    });

    test('neither hides the slot', () {
      expect(
          statusBarSharedSlot(
              targetedMode: false, scopeDiscoveryOn: false, scopeCount: 0),
          StatusBarSlot.hidden);
    });
  });
}
