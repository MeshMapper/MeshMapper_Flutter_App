import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/location_consent.dart';
import 'package:mesh_mapper/services/permission_disclosure_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  // Google Play rejected 1.4.1 for a location disclosure without these.
  group('disclosure wording keeps what Google Play asks for', () {
    for (final (name, lead) in [
      ('location', PermissionDisclosureService.locationDisclosureLead),
      ('background', PermissionDisclosureService.backgroundDisclosureLead),
    ]) {
      test('$name lead says it collects location data in the background', () {
        expect(lead, contains('collects location data'));
        expect(lead, contains('even when the app is closed or not in use'));
      });
    }
  });

  group('LocationConsent.needsDisclosure', () {
    test('until agreed, it shows even with no prompt next', () {
      expect(
          LocationConsent.needsDisclosure(agreed: false, aboutToRequest: false),
          isTrue);
    });

    test('once agreed, it shows again before every system prompt', () {
      expect(
          LocationConsent.needsDisclosure(agreed: true, aboutToRequest: true),
          isTrue);
    });

    test('once agreed and granted, it stays away', () {
      expect(
          LocationConsent.needsDisclosure(agreed: true, aboutToRequest: false),
          isFalse);
    });
  });

  Future<bool?> openAndTap(
    WidgetTester tester,
    Future<bool> Function(BuildContext) show,
    String lead,
    String button,
  ) async {
    bool? result;
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await show(context),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text(lead), findsOneWidget);
    for (final point in PermissionDisclosureService.sharingPoints) {
      expect(find.text(point), findsOneWidget);
    }
    await tester.tap(find.text(button));
    await tester.pumpAndSettle();
    return result;
  }

  group('PermissionDisclosureService.showLocationDisclosure', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    Future<bool?> tap(WidgetTester tester, String button) => openAndTap(
        tester,
        PermissionDisclosureService.showLocationDisclosure,
        PermissionDisclosureService.locationDisclosureLead,
        button);

    testWidgets('Agree allows the system prompt and is remembered',
        (tester) async {
      expect(await tap(tester, 'Agree'), isTrue);
      expect(await LocationConsent.hasAgreed(), isTrue);
    });

    testWidgets('Not Now skips the system prompt and is not remembered',
        (tester) async {
      expect(await tap(tester, 'Not Now'), isFalse);
      expect(
          await LocationConsent.hasAgreed(), isFalse);
    });

    test('Continue on the old dialog still counts as agreeing', () async {
      SharedPreferences.setMockInitialValues(
          {'location_disclosure_shown': true});
      expect(await LocationConsent.hasAgreed(), isTrue);
    });
  });

  group('PermissionDisclosureService.showBackgroundLocationDisclosure', () {
    Future<bool?> tap(WidgetTester tester, String button) => openAndTap(
        tester,
        PermissionDisclosureService.showBackgroundLocationDisclosure,
        PermissionDisclosureService.backgroundDisclosureLead,
        button);

    testWidgets('Agree allows the Always prompt', (tester) async {
      expect(await tap(tester, 'Agree'), isTrue);
    });

    testWidgets('Not Now skips it', (tester) async {
      expect(await tap(tester, 'Not Now'), isFalse);
    });
  });
}
