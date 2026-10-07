import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/store_links.dart';

void main() {
  group('StoreLinks.resolve', () {
    test('iOS TestFlight opens TestFlight', () {
      final link =
          StoreLinks.resolve(TargetPlatform.iOS, 'com.apple.testflight');
      expect(link.label, 'Update in TestFlight');
      expect(link.uri.toString(),
          'itms-beta://beta.itunes.apple.com/v1/app/6758073991');
    });

    for (final installer in ['com.apple', 'com.apple.simulator', null]) {
      test('iOS installer $installer opens the App Store', () {
        final link = StoreLinks.resolve(TargetPlatform.iOS, installer);
        expect(link.label, 'Update MeshMapper');
        expect(link.uri.toString(), 'https://apps.apple.com/app/id6758073991');
      });
    }

    for (final installer in [
      'com.android.vending',
      'com.google.android.feedback',
    ]) {
      test('Android installer $installer opens Google Play', () {
        final link = StoreLinks.resolve(TargetPlatform.android, installer);
        expect(link.label, 'Update MeshMapper');
        expect(link.uri.toString(),
            'https://play.google.com/store/apps/details?id=net.meshmapper.app');
      });
    }

    for (final installer in [
      'com.google.android.packageinstaller',
      'org.fdroid.fdroid',
      null,
    ]) {
      test('Android installer $installer downloads the latest release', () {
        final link = StoreLinks.resolve(TargetPlatform.android, installer);
        expect(link.label, 'Download latest version');
        expect(link.uri.toString(),
            'https://github.com/MeshMapper/MeshMapper_Project/releases/latest');
      });
    }
  });

  group('parseRequiredAppVersion', () {
    test('reads a store minimum', () {
      expect(parseRequiredAppVersion('App version outdated. Required: v1.4.0'),
          '1.4.0');
    });

    test('reads a TestFlight build minimum', () {
      expect(
          parseRequiredAppVersion('Dev version outdated. Required: 1791170991'),
          '1791170991');
    });

    test('drops a trailing full stop', () {
      expect(parseRequiredAppVersion('Required: v1.4.0.'), '1.4.0');
    });

    test('null when the message names no version', () {
      expect(parseRequiredAppVersion('Please update'), isNull);
      expect(parseRequiredAppVersion(null), isNull);
    });
  });

  group('appUpdateVersionLine', () {
    test('store build shows versions', () {
      expect(appUpdateVersionLine('APP-1.3.0', '1.4.0'),
          'Your version: 1.3.0 · Needed: 1.4.0');
    });

    test('TestFlight build shows build numbers', () {
      expect(appUpdateVersionLine('APP-1790996175', '1791170991'),
          'Your build: 1790996175 · Needed: 1791170991');
    });

    test('unknown minimum shows only our own version', () {
      expect(appUpdateVersionLine('APP-1.3.0', null), 'Your version: 1.3.0');
    });
  });
}
