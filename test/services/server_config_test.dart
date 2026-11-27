import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/api_service.dart';
import 'package:mesh_mapper/services/debug_submit_service.dart';
import 'package:mesh_mapper/services/device_model_service.dart';
import 'package:mesh_mapper/services/portal_account_service.dart';
import 'package:mesh_mapper/services/portal_token_store.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_api.dart';
import 'package:mesh_mapper/services/server_config.dart';

const _liveKey = 'live-key-for-tests';
const _customKey = 'custom-key-for-tests';

void main() {
  setUp(() {
    ServerConfig.resetForTest();
    ServerConfig.buildKeyForTest = _liveKey;
  });
  tearDown(ServerConfig.resetForTest);

  group('Live (the default)', () {
    test('every address is the one the app has always used', () {
      expect(ServerConfig.isCustom, isFalse);
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

  group('Custom', () {
    setUp(() {
      expect(
          ServerConfig.useCustom(
              domain: 'https://Dev.Example.org/', key: ' $_customKey '),
          isTrue);
    });

    test('every address derives from the one base domain', () {
      expect(ServerConfig.isCustom, isTrue);
      expect(ServerConfig.baseDomain, 'dev.example.org');
      expect(ApiService.baseUrl, 'https://dev.example.org');
      expect(ApiService.wardriveEndpoint,
          'https://dev.example.org/wardrive-api.php/wardrive');
      expect(ApiService.geoAuthStatusUrl,
          'https://dev.example.org/wardrive-api.php/status');
      expect(ApiService.geoAuthUrl,
          'https://dev.example.org/wardrive-api.php/auth');
      expect(ApiService.borderUrl,
          'https://dev.example.org/wardrive-api.php/border');
      expect(ApiService.deviceCatalogUrl,
          'https://dev.example.org/wardrive-api.php/devices');
      expect(RepeaterAdminApi.endpoint,
          'https://dev.example.org/wardrive-api.php/repeater');
      expect(ServerConfig.regionHost('YOW'), 'yow.dev.example.org');
      expect(ServerConfig.regionUrl('yul'), 'https://yul.dev.example.org');
      expect(PortalApi.baseUrl, 'https://portal.dev.example.org');
      expect(PortalApi.action('me').toString(),
          'https://portal.dev.example.org/portal_app_api.php?action=me');
      expect(DebugSubmitService.baseUrl,
          'https://dev.example.org/debug/submitdebug.php');
    });

    test('the key is the custom key, and Live gets its own back', () {
      expect(ApiService.apiKey, _customKey);
      ServerConfig.useLive();
      expect(ApiService.apiKey, _liveKey);
    });

    test('everything stored is named for the server', () {
      expect(ServerConfig.storageSuffix, '@dev.example.org');
      expect(SecureTokenStore.tokenKey, 'portal_app_token@dev.example.org');
      expect(SecureTokenStore.pendingPkceKey,
          'portal_pending_pkce@dev.example.org');
      expect(DeviceModelService.catalogCacheKey,
          'device_catalog_v1@dev.example.org');
      expect(DeviceModelService.outboxKey,
          'device_catalog_unknown_outbox_v1@dev.example.org');
      expect(ServerConfig.recordTag, 'dev.example.org');
    });

    test('a record only belongs to the server it names', () {
      expect(ServerConfig.ownsRecord('dev.example.org'), isTrue);
      expect(ServerConfig.ownsRecord(null), isFalse, reason: 'untagged = Live');
      expect(ServerConfig.ownsRecord('other.example.org'), isFalse);
      ServerConfig.useLive();
      expect(ServerConfig.ownsRecord(null), isTrue);
      expect(ServerConfig.ownsRecord(''), isTrue);
      expect(ServerConfig.ownsRecord('dev.example.org'), isFalse);
    });

    test('a change of server bumps the revision, a repeat does not', () {
      final before = ServerConfig.revision.value;
      ServerConfig.useCustom(domain: 'dev.example.org', key: _customKey);
      expect(ServerConfig.revision.value, before);
      ServerConfig.useCustom(domain: 'dev.example.org', key: 'another-key');
      expect(ServerConfig.revision.value, before + 1);
      ServerConfig.useLive();
      expect(ServerConfig.revision.value, before + 2);
      ServerConfig.useLive();
      expect(ServerConfig.revision.value, before + 2);
    });
  });

  group('Custom is refused unless both fields are usable', () {
    test('no key', () {
      expect(ServerConfig.useCustom(domain: 'dev.example.org', key: '  '),
          isFalse);
      expect(ServerConfig.isCustom, isFalse);
      expect(ApiService.apiKey, _liveKey);
    });

    test('no usable host', () {
      expect(ServerConfig.useCustom(domain: 'not a host', key: _customKey),
          isFalse);
      expect(ServerConfig.isCustom, isFalse);
    });

    test('the live domain itself: a custom key never goes to live', () {
      for (final live in [
        'meshmapper.net',
        'https://meshmapper.net',
        'MeshMapper.net/',
        'www.meshmapper.net',
      ]) {
        expect(ServerConfig.useCustom(domain: live, key: _customKey), isFalse,
            reason: live);
        expect(ServerConfig.isCustom, isFalse);
        expect(ServerConfig.domainProblem(live), contains('live server'));
      }
    });
  });

  group('normalizeDomain', () {
    test('accepts a host name, with or without https', () {
      expect(ServerConfig.normalizeDomain('dev.meshmapper.net'),
          'dev.meshmapper.net');
      expect(ServerConfig.normalizeDomain('https://dev.meshmapper.net'),
          'dev.meshmapper.net');
      expect(ServerConfig.normalizeDomain('  HTTPS://Dev.Example.ORG/  '),
          'dev.example.org');
      expect(ServerConfig.normalizeDomain('a-b.example.co'), 'a-b.example.co');
    });

    test('refuses everything that is not a bare https host name', () {
      for (final bad in [
        '',
        'http://dev.example.org',
        'ftp://dev.example.org',
        'dev.example.org/path',
        'https://dev.example.org/wardrive-api.php',
        'dev.example.org:8443',
        'user@dev.example.org',
        'user:pw@dev.example.org',
        'dev.example.org?x=1',
        'dev.example.org#x',
        'localhost',
        '192.168.1.10',
        '100.64.0.1',
        '[fe80::1]',
        'dev..example.org',
        '-dev.example.org',
        'dev example.org',
        'dev.example.org//',
        '${'a' * 64}.example.org',
      ]) {
        expect(ServerConfig.normalizeDomain(bad), isNull, reason: '"$bad"');
      }
    });

    test('says why in words', () {
      expect(ServerConfig.domainProblem('dev.example.org'), isNull);
      expect(ServerConfig.domainProblem('http://dev.example.org'),
          contains('https'));
      expect(ServerConfig.domainProblem('dev.example.org/x'),
          contains('host name'));
      expect(ServerConfig.domainProblem(''), isNotNull);
    });
  });
}
