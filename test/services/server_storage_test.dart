import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/offline_session_service.dart';
import 'package:mesh_mapper/services/portal_account_service.dart';
import 'package:mesh_mapper/services/portal_token_store.dart';
import 'package:mesh_mapper/services/server_config.dart';
import 'package:mesh_mapper/services/server_settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _liveKey = 'live-key-for-tests';
const _customKey = 'custom-key-for-tests';

/// The keystore as a plain map, so the names written can be inspected.
class _MapSecureStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    values.remove(key);
  }
}

void _useCustom([String domain = 'dev.example.org']) =>
    ServerConfig.useCustom(domain: domain, key: _customKey);

List<Map<String, dynamic>> _pings(int n) =>
    List.generate(n, (i) => {'type': 'TX', 'seq': i});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    ServerConfig.resetForTest();
    ServerConfig.buildKeyForTest = _liveKey;
  });
  tearDown(ServerConfig.resetForTest);

  group('portal sign-in (keystore)', () {
    test('each server has its own token and pending sign-in', () async {
      final storage = _MapSecureStorage();
      final store = SecureTokenStore(storage: storage);
      final pending = PendingPkce(
          verifier: 'v' * 43, state: 'live-state', createdAt: DateTime.now());

      await store.writeToken('live-token');
      await store.writePendingPkce(pending);

      _useCustom();
      expect(await store.readToken(), isNull,
          reason: 'the live sign-in is not visible on a custom server');
      expect(await store.readPendingPkce(), isNull);
      await store.writeToken('custom-token');
      expect(await store.readToken(), 'custom-token');

      ServerConfig.useLive();
      expect(await store.readToken(), 'live-token');
      expect((await store.readPendingPkce())?.state, 'live-state');

      expect(storage.values['portal_app_token'], 'live-token');
      expect(storage.values['portal_app_token@dev.example.org'],
          'custom-token');
    });

    test('signing out on one server leaves the other signed in', () async {
      final storage = _MapSecureStorage();
      final store = SecureTokenStore(storage: storage);
      await store.writeToken('live-token');
      _useCustom();
      await store.writeToken('custom-token');
      await store.deleteToken();
      await store.deletePendingPkce();
      expect(await store.readToken(), isNull);
      ServerConfig.useLive();
      expect(await store.readToken(), 'live-token');
    });

    test('two custom servers do not share a sign-in either', () async {
      final store = SecureTokenStore(storage: _MapSecureStorage());
      _useCustom('dev.example.org');
      await store.writeToken('token-a');
      _useCustom('staging.example.org');
      expect(await store.readToken(), isNull);
    });
  });

  group('portal account service', () {
    late InMemoryTokenStore store;
    late List<http.Request> requests;

    PortalAccountService build(
            Future<http.Response> Function(http.Request) responder) =>
        PortalAccountService(
          client: MockClient((request) async {
            requests.add(request);
            return responder(request);
          }),
          store: store,
          launcher: (uri) async => true,
        );

    setUp(() {
      store = InMemoryTokenStore();
      requests = [];
    });

    test('a switch drops the old sign-in from memory and loads the new one',
        () async {
      store.token = 'L' * 64;
      final service = build((_) async => http.Response(
          jsonEncode({
            'ok': true,
            'user': {'id': 7, 'username': 'live-user'},
            'pubkeys': [],
          }),
          200));
      await service.init();
      expect(service.isSignedIn, isTrue);
      await service.refreshMe(force: true);
      expect(service.account?.username, 'live-user');

      _useCustom();
      await service.reloadForServer();
      expect(service.isSignedIn, isFalse);
      expect(service.account, isNull);
      expect(service.linkedPubkeys, isEmpty);

      // Nothing authenticated is sent while signed out on the new server.
      requests.clear();
      await service.refreshMe(force: true);
      expect(requests, isEmpty,
          reason: 'the live token must never be sent to another server');

      ServerConfig.useLive();
      await service.reloadForServer();
      expect(service.isSignedIn, isTrue, reason: 'the live sign-in is kept');
    });

    test('the token only ever goes to the portal of its own server',
        () async {
      store.token = 'L' * 64;
      _useCustom();
      store.token = 'C' * 64;
      ServerConfig.useLive();

      final service = build((_) async => http.Response(
          jsonEncode({
            'ok': true,
            'user': {'id': 7, 'username': 'someone'},
            'pubkeys': [],
          }),
          200));
      await service.init();
      await service.refreshMe(force: true);
      _useCustom();
      await service.reloadForServer();
      await service.refreshMe(force: true);

      expect(requests, hasLength(2));
      expect(requests[0].url.host, 'portal.meshmapper.net');
      expect(requests[0].headers['X-MM-App-Token'], 'L' * 64);
      expect(requests[1].url.host, 'portal.dev.example.org');
      expect(requests[1].headers['X-MM-App-Token'], 'C' * 64);
    });

    test('an answer that lands after a switch is dropped', () async {
      store.token = 'L' * 64;
      final service = build((_) async {
        // The server changes while the request is on the wire.
        _useCustom();
        return http.Response(
            jsonEncode({
              'ok': true,
              'user': {'id': 7, 'username': 'live-user'},
              'pubkeys': [
                {'pubkey': 'AB' * 32, 'label': 'x', 'name': 'x', 'points': 1}
              ],
            }),
            200);
      });
      await service.init();
      final refreshed = await service.refreshMe(force: true);
      expect(refreshed, isFalse);
      expect(service.account, isNull,
          reason: 'a live answer must not become the custom server state');
      expect(service.linkedPubkeys, isEmpty);
    });
  });

  group('offline sessions', () {
    Future<OfflineSessionService> fresh() async {
      final service = OfflineSessionService();
      await service.init();
      return service;
    }

    test('a session recorded on Live is untagged, as it always was', () async {
      SharedPreferences.setMockInitialValues({});
      final service = await fresh();
      await service.saveSession(_pings(2), deviceName: 'Radio');
      final stored = (await SharedPreferences.getInstance())
          .getStringList('offline_sessions')!;
      final json = jsonDecode(stored.single) as Map<String, dynamic>;
      expect(json.containsKey('server'), isFalse);
      expect(service.sessions.single.server, isNull);
    });

    test('a session recorded on a custom server names it', () async {
      SharedPreferences.setMockInitialValues({});
      _useCustom();
      final service = await fresh();
      await service.saveSession(_pings(2));
      expect(service.sessions.single.server, 'dev.example.org');
      // The tag is storage metadata: it is not part of what is uploaded.
      expect(service.sessions.single.data.containsKey('server'), isFalse);
    });

    test('an untagged stored session means Live', () async {
      SharedPreferences.setMockInitialValues({
        'offline_sessions': [
          jsonEncode({
            'filename': '2026-01-01.json',
            'createdAt': '2026-01-01T10:00:00.000',
            'pingCount': 1,
            'data': {'pings': _pings(1)},
          })
        ],
      });
      final service = await fresh();
      expect(service.sessions, hasLength(1));
      _useCustom();
      service.onServerChanged();
      expect(service.sessions, isEmpty);
      expect(service.getSession('2026-01-01.json'), isNull);
      expect(service.getSessionData('2026-01-01.json'), isNull);
    });

    test('only the active server can list, read, change or delete its own',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = await fresh();
      await service.saveSession(_pings(3));
      final liveName = service.sessions.single.filename;

      _useCustom();
      service.onServerChanged();
      expect(service.sessionCount, 0);
      await service.updateCurrentSession(_pings(4));
      service.finalizeCurrentSession();
      final customName = service.sessions.single.filename;
      expect(customName, isNot(liveName));

      // From the custom server, the live session cannot be touched.
      await service.markAsUploaded(liveName);
      await service.removeProcessedPings(liveName, 1);
      await service.replacePings(liveName, _pings(1));
      await service.deleteSession(liveName);
      await service.clearAll();
      expect(service.sessions, isEmpty);

      ServerConfig.useLive();
      service.onServerChanged();
      final live = service.sessions.single;
      expect(live.filename, liveName);
      expect(live.pingCount, 3);
      expect(live.uploaded, isFalse);
    });

    test('the tag survives every rewrite of the session', () async {
      SharedPreferences.setMockInitialValues({});
      _useCustom();
      final service = await fresh();
      await service.updateCurrentSession(_pings(2));
      await service.updateCurrentSession(_pings(5));
      final name = service.sessions.single.filename;
      await service.removeProcessedPings(name, 1);
      await service.replacePings(name, _pings(2));
      await service.markAsUploaded(name);

      final reloaded = await fresh();
      expect(reloaded.sessions.single.server, 'dev.example.org');
      expect(reloaded.sessions.single.uploaded, isTrue);
    });

    test('an auto-save after a switch never updates the other server\'s file',
        () async {
      SharedPreferences.setMockInitialValues({});
      final service = await fresh();
      await service.updateCurrentSession(_pings(2));
      final liveName = service.sessions.single.filename;

      _useCustom();
      service.onServerChanged();
      await service.updateCurrentSession(_pings(9));
      expect(service.sessions.single.filename, isNot(liveName));
      expect(service.sessions.single.server, 'dev.example.org');

      ServerConfig.useLive();
      service.onServerChanged();
      expect(service.sessions.single.pingCount, 2);
    });

    test('listeners get the new server\'s list on a switch', () async {
      SharedPreferences.setMockInitialValues({});
      final service = await fresh();
      await service.saveSession(_pings(1));
      List<OfflineSession>? seen;
      service.onSessionsUpdated = (sessions) => seen = sessions;
      _useCustom();
      service.onServerChanged();
      expect(seen, isEmpty);
    });
  });

  group('the stored server choice', () {
    late Directory dir;
    late Box<dynamic> box;
    late InMemoryTokenStore keys;
    late ServerSettingsStore store;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('server_settings_test');
      Hive.init(dir.path);
      box = await Hive.openBox('user_preferences');
      keys = InMemoryTokenStore();
      store = ServerSettingsStore(keys: keys);
    });

    tearDown(() async {
      await Hive.deleteFromDisk();
      await Hive.close();
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });

    test('nothing stored reads as Live', () async {
      final settings = await store.load(box);
      expect(settings.custom, isFalse);
      expect(settings.customActive, isFalse);
    });

    test('round trip: the host in the box, the key in the keystore only',
        () async {
      await store.save(
          box,
          const ServerSettings(
              custom: true, domain: 'dev.example.org', key: _customKey));
      expect(box.get('developer_server'),
          {'custom': true, 'domain': 'dev.example.org'});
      expect(box.toMap().toString(), isNot(contains(_customKey)),
          reason: 'the key is never written to the preferences box');
      expect(keys.serverKey, _customKey);

      final settings = await store.load(box);
      expect(settings.custom, isTrue);
      expect(settings.domain, 'dev.example.org');
      expect(settings.key, _customKey);
      expect(settings.customActive, isTrue);
    });

    test('the key never appears in the text form', () {
      const settings = ServerSettings(
          custom: true, domain: 'dev.example.org', key: _customKey);
      expect(settings.toString(), isNot(contains(_customKey)));
    });

    test('clearing the key removes it from the keystore', () async {
      await store.save(
          box,
          const ServerSettings(
              custom: true, domain: 'dev.example.org', key: _customKey));
      await store.save(box,
          const ServerSettings(custom: true, domain: 'dev.example.org'));
      expect(keys.serverKey, isNull);
    });

    test('Custom is not active until both fields are filled', () {
      const noKey = ServerSettings(custom: true, domain: 'dev.example.org');
      const noHost = ServerSettings(custom: true, key: _customKey);
      const badHost =
          ServerSettings(custom: true, domain: 'http://x', key: _customKey);
      const notChosen =
          ServerSettings(domain: 'dev.example.org', key: _customKey);
      for (final settings in [noKey, noHost, badHost, notChosen]) {
        expect(settings.customActive, isFalse, reason: '$settings');
        ServerSettingsStore.apply(settings, developerMode: true);
        expect(ServerConfig.isCustom, isFalse, reason: '$settings');
        expect(ServerConfig.apiKey, _liveKey);
      }
    });

    test('a complete Custom choice is only used with developer mode on', () {
      const settings = ServerSettings(
          custom: true, domain: 'dev.example.org', key: _customKey);
      ServerSettingsStore.apply(settings, developerMode: false);
      expect(ServerConfig.isCustom, isFalse);
      ServerSettingsStore.apply(settings, developerMode: true);
      expect(ServerConfig.isCustom, isTrue);
      expect(ServerConfig.baseDomain, 'dev.example.org');
      // Developer mode switched off: back to Live.
      ServerSettingsStore.apply(settings, developerMode: false);
      expect(ServerConfig.isCustom, isFalse);
      expect(ServerConfig.apiKey, _liveKey);
    });

    test('at startup: Live unless developer mode and a full Custom choice',
        () async {
      await box.close();
      await store.applyAtStartup();
      expect(ServerConfig.isCustom, isFalse, reason: 'a fresh install');

      box = await Hive.openBox('user_preferences');
      await store.save(
          box,
          const ServerSettings(
              custom: true, domain: 'dev.example.org', key: _customKey));
      await box.put('preferences', {'developerModeEnabled': false});
      await store.applyAtStartup();
      expect(ServerConfig.isCustom, isFalse, reason: 'developer mode is off');

      await box.put('preferences', {'developerModeEnabled': true});
      await store.applyAtStartup();
      expect(ServerConfig.isCustom, isTrue);
      expect(ServerConfig.baseDomain, 'dev.example.org');
      expect(ServerConfig.apiKey, _customKey);

      await store.save(box,
          const ServerSettings(custom: false, domain: 'dev.example.org'));
      await store.applyAtStartup();
      expect(ServerConfig.isCustom, isFalse, reason: 'Live was chosen');
    });

    test('a lost key (keystore wiped) falls back to Live at startup', () async {
      await store.save(
          box,
          const ServerSettings(
              custom: true, domain: 'dev.example.org', key: _customKey));
      await box.put('preferences', {'developerModeEnabled': true});
      keys.serverKey = null;
      await store.applyAtStartup();
      expect(ServerConfig.isCustom, isFalse);
      expect(ServerConfig.apiKey, _liveKey);
    });
  });
}
