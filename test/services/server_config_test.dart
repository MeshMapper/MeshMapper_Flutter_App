import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/debug_submit_service.dart';
import 'package:mesh_mapper/services/device_model_service.dart';
import 'package:mesh_mapper/services/portal_account_service.dart';
import 'package:mesh_mapper/services/portal_token_store.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_api.dart';
import 'package:mesh_mapper/services/server_config.dart';

const _liveKey = 'live-key-for-tests';
const _devKey = 'dev-key-for-tests';

void main() {
  setUp(() {
    ServerConfig.resetForTest();
    ServerConfig.buildKeyForTest = _liveKey;
  });
  tearDown(ServerConfig.resetForTest);

  group('Live (the default)', () {
    test('every address is the one the app has always used', () {
      expect(ServerConfig.isDev, isFalse);
      expect(ServerConfig.baseDomain, 'meshmapper.net');
      expect(ApiService.baseUrl, 'https://meshmapper.net');
      expect(ApiService.wardriveEndpoint,
          'https://meshmapper.net/wardrive-api.php/wardrive');
      expect(ApiService.geoAuthStatusUrl,
          'https://meshmapper.net/wardrive-api.php/status');
      expect(ApiService.geoAuthUrl,
          'https://meshmapper.net/wardrive-api.php/auth');
      expect(ApiService.borderUrl,
          'https://meshmapper.net/wardrive-api.php/border');
      expect(ApiService.deviceCatalogUrl,
          'https://meshmapper.net/wardrive-api.php/devices');
      expect(RepeaterAdminApi.endpoint,
          'https://meshmapper.net/wardrive-api.php/repeater');
      expect(ServerConfig.regionHost('YOW'), 'yow.meshmapper.net');
      expect(ServerConfig.regionUrl('ONQC'), 'https://onqc.meshmapper.net');
      expect(PortalApi.baseUrl, 'https://portal.meshmapper.net');
      expect(ServerConfig.portalHost, 'portal.meshmapper.net');
      expect(DebugSubmitService.baseUrl,
          'https://meshmapper.net/debug/submitdebug.php');
      expect(ServerConfig.onboardingUrl, 'https://meshmapper.net/?onboarding');
    });

    test('the key is the build-time key', () {
      expect(ApiService.apiKey, _liveKey);
      expect(ServerConfig.apiKey, _liveKey);
    });

    test('storage names are the ones a normal install already has', () {
      expect(ServerConfig.storageSuffix, '');
      expect(ServerConfig.scoped('offline_sessions'), 'offline_sessions');
      expect(SecureTokenStore.tokenKey, 'portal_app_token');
      expect(SecureTokenStore.pendingPkceKey, 'portal_pending_pkce');
      expect(DeviceModelService.catalogCacheKey, 'device_catalog_v1');
      expect(DeviceModelService.outboxKey, 'device_catalog_unknown_outbox_v1');
      expect(ServerConfig.recordTag, isNull);
    });
  });

  group('Dev server', () {
    setUp(() {
      expect(ServerConfig.useDev(key: ' $_devKey '), isTrue);
    });

    test('every address derives from the one fixed dev domain', () {
      expect(ServerConfig.isDev, isTrue);
      expect(ServerConfig.devDomain, 'dev.meshmapper.net');
      expect(ServerConfig.baseDomain, 'dev.meshmapper.net');
      expect(ApiService.baseUrl, 'https://dev.meshmapper.net');
      expect(ApiService.wardriveEndpoint,
          'https://dev.meshmapper.net/wardrive-api.php/wardrive');
      expect(ApiService.geoAuthStatusUrl,
          'https://dev.meshmapper.net/wardrive-api.php/status');
      expect(ApiService.geoAuthUrl,
          'https://dev.meshmapper.net/wardrive-api.php/auth');
      expect(ApiService.borderUrl,
          'https://dev.meshmapper.net/wardrive-api.php/border');
      expect(ApiService.deviceCatalogUrl,
          'https://dev.meshmapper.net/wardrive-api.php/devices');
      expect(RepeaterAdminApi.endpoint,
          'https://dev.meshmapper.net/wardrive-api.php/repeater');
      expect(ServerConfig.regionHost('YOW'), 'yow.dev.meshmapper.net');
      expect(ServerConfig.regionUrl('yul'), 'https://yul.dev.meshmapper.net');
      expect(PortalApi.baseUrl, 'https://portal.dev.meshmapper.net');
      expect(PortalApi.action('me').toString(),
          'https://portal.dev.meshmapper.net/portal_app_api.php?action=me');
      expect(DebugSubmitService.baseUrl,
          'https://dev.meshmapper.net/debug/submitdebug.php');
    });

    test('the key is the dev key, and Live gets its own back', () {
      expect(ApiService.apiKey, _devKey);
      ServerConfig.useLive();
      expect(ApiService.apiKey, _liveKey);
    });

    test('everything stored is named for the server', () {
      expect(ServerConfig.storageSuffix, '@dev.meshmapper.net');
      expect(SecureTokenStore.tokenKey, 'portal_app_token@dev.meshmapper.net');
      expect(SecureTokenStore.pendingPkceKey,
          'portal_pending_pkce@dev.meshmapper.net');
      expect(DeviceModelService.catalogCacheKey,
          'device_catalog_v1@dev.meshmapper.net');
      expect(DeviceModelService.outboxKey,
          'device_catalog_unknown_outbox_v1@dev.meshmapper.net');
      expect(ServerConfig.recordTag, 'dev.meshmapper.net');
    });

    test('a record only belongs to the server it names', () {
      expect(ServerConfig.ownsRecord('dev.meshmapper.net'), isTrue);
      expect(ServerConfig.ownsRecord(null), isFalse, reason: 'untagged = Live');
      expect(ServerConfig.ownsRecord('other.example.org'), isFalse);
      ServerConfig.useLive();
      expect(ServerConfig.ownsRecord(null), isTrue);
      expect(ServerConfig.ownsRecord(''), isTrue);
      expect(ServerConfig.ownsRecord('dev.meshmapper.net'), isFalse);
    });

    test('a change of server bumps the revision, a repeat does not', () {
      final before = ServerConfig.revision.value;
      ServerConfig.useDev(key: _devKey);
      expect(ServerConfig.revision.value, before);
      ServerConfig.useDev(key: 'another-key');
      expect(ServerConfig.revision.value, before + 1);
      ServerConfig.useLive();
      expect(ServerConfig.revision.value, before + 2);
      ServerConfig.useLive();
      expect(ServerConfig.revision.value, before + 2);
    });
  });

  group('the dev server needs its own key', () {
    test('no key: refused, the app stays on Live with the live key', () {
      for (final blank in ['', '   ']) {
        expect(ServerConfig.useDev(key: blank), isFalse);
        expect(ServerConfig.isDev, isFalse);
        expect(ServerConfig.baseDomain, 'meshmapper.net');
        expect(ApiService.apiKey, _liveKey);
      }
    });
  });

  group('the app cannot be pointed anywhere else', () {
    test('there are exactly two base domains, both fixed', () {
      expect(ServerConfig.baseDomain, ServerConfig.liveDomain);
      ServerConfig.useDev(key: _devKey);
      expect(ServerConfig.baseDomain, ServerConfig.devDomain);
      ServerConfig.useDev(key: 'https://evil.example.org');
      expect(ServerConfig.baseDomain, ServerConfig.devDomain,
          reason: 'whatever is typed is only ever a key');
    });

    test('nothing under lib/ offers a way to type or store an address', () {
      final source = [
        'lib/services/server_config.dart',
        'lib/services/server_settings_store.dart',
        'lib/services/server_probe.dart',
        'lib/screens/settings/server_settings_card.dart',
      ].map((path) => File(path).readAsStringSync()).join('\n');
      for (final gone in [
        'normalizeDomain',
        'useCustom',
        'Server URL',
        "'domain'",
        'required String domain',
      ]) {
        expect(source.contains(gone), isFalse, reason: gone);
      }
    });
  });
}
