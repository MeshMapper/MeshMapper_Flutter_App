import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';

import '../utils/debug_logger_io.dart';
import 'portal_token_store.dart';
import 'server_config.dart';

/// What the developer chose on the Developer Tools page.
///
/// [custom] with a [domain] and a key is a custom server; anything less is
/// Live. The key itself is never part of this object's text form.
class ServerSettings {
  /// Whether "Custom" is selected.
  final bool custom;

  /// The custom server's base domain as stored (bare host), or empty.
  final String domain;

  /// The custom server's app key, or empty. Never logged.
  final String key;

  const ServerSettings({
    this.custom = false,
    this.domain = '',
    this.key = '',
  });

  static const ServerSettings live = ServerSettings();

  /// Custom is only active with a usable host name AND a key.
  bool get customActive =>
      custom &&
      key.trim().isNotEmpty &&
      ServerConfig.normalizeDomain(domain) != null;

  @override
  String toString() => 'ServerSettings(custom: $custom, domain: $domain, '
      'key: ${key.isEmpty ? 'none' : 'set'})';
}

/// Where the custom server's app key is kept: the keychain or keystore.
abstract class ServerKeyStore {
  Future<String?> readServerKey();
  Future<void> writeServerKey(String key);
  Future<void> deleteServerKey();
}

/// Reads and writes the developer's server choice.
///
/// The mode and the host sit in the preferences box under their own key,
/// outside the user preferences object. The key goes to [ServerKeyStore].
class ServerSettingsStore {
  static const String preferencesBoxName = 'user_preferences';
  static const String settingsKey = 'developer_server';

  final ServerKeyStore _keys;

  ServerSettingsStore({ServerKeyStore? keys}) : _keys = keys ?? _defaultKeys();

  static ServerKeyStore _defaultKeys() {
    if (kIsWeb) return InMemoryTokenStore();
    return SecureTokenStore();
  }

  /// The stored choice. Anything unreadable reads as Live.
  Future<ServerSettings> load(Box<dynamic> box) async {
    try {
      final raw = box.get(settingsKey);
      if (raw is! Map) return ServerSettings.live;
      final domain = raw['domain'];
      final key = await _keys.readServerKey();
      return ServerSettings(
        custom: raw['custom'] == true,
        domain: domain is String ? domain : '',
        key: key ?? '',
      );
    } catch (e) {
      debugWarn('[SERVER] Stored server choice unreadable (${e.runtimeType}), '
          'using Live');
      return ServerSettings.live;
    }
  }

  Future<void> save(Box<dynamic> box, ServerSettings settings) async {
    await box.put(settingsKey, {
      'custom': settings.custom,
      'domain': settings.domain,
    });
    if (settings.key.isEmpty) {
      await _keys.deleteServerKey();
    } else {
      await _keys.writeServerKey(settings.key);
    }
  }

  /// Points [ServerConfig] at what [settings] describe. A custom server is
  /// only used with developer mode on; otherwise the app is on Live.
  static void apply(ServerSettings settings, {required bool developerMode}) {
    if (developerMode && settings.customActive) {
      ServerConfig.useCustom(domain: settings.domain, key: settings.key);
    } else {
      ServerConfig.useLive();
    }
  }

  /// Called once before the app starts: every later request, in every
  /// service, reads the server from [ServerConfig].
  Future<void> applyAtStartup() async {
    try {
      final box = await Hive.openBox(preferencesBoxName)
          .timeout(const Duration(seconds: 5));
      final prefs = box.get('preferences');
      final developerMode =
          prefs is Map && prefs['developerModeEnabled'] == true;
      // The keystore is only read when a custom server was chosen at all.
      final raw = box.get(settingsKey);
      if (!developerMode || raw is! Map || raw['custom'] != true) {
        ServerConfig.useLive();
        return;
      }
      apply(await load(box), developerMode: developerMode);
      debugLog('[SERVER] Using ${ServerConfig.isCustom ? 'custom server '
          '${ServerConfig.baseDomain}' : 'Live'}');
    } catch (e) {
      ServerConfig.useLive();
      debugWarn('[SERVER] Could not read the server choice '
          '(${e.runtimeType}), using Live');
    }
  }
}
