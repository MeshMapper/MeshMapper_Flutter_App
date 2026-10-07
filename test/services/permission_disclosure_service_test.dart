import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/permission_disclosure_service.dart';

void main() {
  group('PermissionDisclosureService.deniedWithoutDialog', () {
    test('an instant denial means no dialog was shown', () {
      expect(
        PermissionDisclosureService.deniedWithoutDialog(
            const Duration(milliseconds: 150)),
        isTrue,
      );
    });

    test('a denial that took human time came from a dialog', () {
      expect(
        PermissionDisclosureService.deniedWithoutDialog(
            const Duration(seconds: 2)),
        isFalse,
      );
    });

    test('the threshold itself counts as a dialog answer', () {
      expect(
        PermissionDisclosureService.deniedWithoutDialog(
            PermissionDisclosureService.silentDenialThreshold),
        isFalse,
      );
    });
  });
}
