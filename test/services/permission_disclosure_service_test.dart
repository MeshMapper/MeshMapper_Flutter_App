import 'package:flutter/foundation.dart';
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

  // Background location is used only while a radio is connected, so neither
  // lead may claim use "even when the app is closed or not in use".
  group('disclosure wording says background use follows the connection', () {
    test('the location lead is the approved copy', () {
      expect(
        PermissionDisclosureService.locationDisclosureLead,
        'MeshMapper collects and uses location data while the app is open, '
        'to show you on the map and check which region you are in. While it '
        'is connected to your radio, it also uses location to keep the radio '
        'signed in and, while a wardriving mode runs, to tag your pings and '
        'map coverage, including with the screen off or another app open. '
        'When you disconnect and leave the app, MeshMapper stops using your '
        'location.',
      );
    });

    test('the background lead is the approved copy', () {
      expect(
        PermissionDisclosureService.backgroundDisclosureLead,
        'MeshMapper collects location data in the background only while your '
        'radio is connected, to keep tagging pings and mapping coverage '
        'during a wardriving mode. When you disconnect, it stops.',
      );
    });

    for (final (name, lead) in [
      ('location', PermissionDisclosureService.locationDisclosureLead),
      ('background', PermissionDisclosureService.backgroundDisclosureLead),
    ]) {
      test('$name lead no longer claims use while the app is closed', () {
        expect(
            lead, isNot(contains('even when the app is closed or not in use')));
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
    tearDown(() => debugDefaultTargetPlatformOverride = null);

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

    // The binding checks foundation overrides before tearDown runs, so each
    // test puts the platform back itself.
    Future<void> openDialog(
        WidgetTester tester, TargetPlatform platform) async {
      debugDefaultTargetPlatformOverride = platform;
      try {
        await tester.pumpWidget(MaterialApp(
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  PermissionDisclosureService.showLocationDisclosure(context),
              child: const Text('open'),
            ),
          ),
        ));
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    }

    testWidgets('on Android it mentions the connected-radio notification',
        (tester) async {
      await openDialog(tester, TargetPlatform.android);
      expect(find.text(PermissionDisclosureService.androidNotificationPoint),
          findsOneWidget);
    });

    testWidgets('on iOS it leaves the notification line out', (tester) async {
      await openDialog(tester, TargetPlatform.iOS);
      expect(find.text(PermissionDisclosureService.locationDisclosureLead),
          findsOneWidget);
      expect(find.text(PermissionDisclosureService.androidNotificationPoint),
          findsNothing);
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
