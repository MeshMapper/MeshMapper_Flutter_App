import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:hive_flutter/hive_flutter.dart';

import '../utils/debug_logger_io.dart';
import 'portal_token_store.dart';
import 'server_config.dart';

/// What the developer chose on the Developer Tools page.
///
/// [dev] with a key is the dev server; anything less is Live. There is no
/// address to choose: the dev server is fixed in [ServerConfig]. The key
/// itself is never part of this object's text form.
class ServerSettings {
  /// Whether "Dev server" is switched on.
  final bool dev;

  /// The dev server's app key, or empty. Never logged.
  final String key;

  const ServerSettings({this.dev = false, this.key = ''});

  static const ServerSettings live = ServerSettings();

  /// The dev server is only active once its key has been entered.
  bool get devActive => dev && key.trim().isNotEmpty;

  @override
  String toString() =>
      'ServerSettings(dev: $dev, key: ${key.isEmpty ? 'none' : 'set'})';
}

/// Where the dev server's app key is kept: the keychain or keystore.
abstract class ServerKeyStore {
  Future<String?> readServerKey();
  Future<void> writeServerKey(String key);
  Future<void> deleteServerKey();
}

/// Reads and writes the developer's server choice.
///
/// The switch sits in the preferences box under its own key, outside the
/// user preferences object. The key goes to [ServerKeyStore].
class ServerSettingsStore {
  static const String preferencesBoxName = 'user_preferences';
  static const String settingsKey = 'developer_server';

  final ServerKeyStore _keys;

  ServerSettingsStore({ServerKeyStore? keys}) : _keys = keys ?? _defaultKeys();

  static ServerKeyStore _defaultKeys() {
    if (kIsWeb) return InMemoryTokenStore();
    return SecureTokenStore();
  }

  static bool _devChosen(Object? raw) => raw is Map && raw['dev'] == true;

  /// The stored choice. Anything unreadable reads as Live.
  Future<ServerSettings> load(Box<dynamic> box) async {
    try {
      final raw = box.get(settingsKey);
      if (raw is! Map) return ServerSettings.live;
      final key = await _keys.readServerKey();
      return ServerSettings(dev: _devChosen(raw), key: key ?? '');
    } catch (e) {
      debugWarn('[SERVER] Stored server choice unreadable (${e.runtimeType}), '
          'using Live');
      return ServerSettings.live;
    }
  }

  Future<void> save(Box<dynamic> box, ServerSettings settings) async {
    await box.put(settingsKey, {'dev': settings.dev});
    if (settings.key.isEmpty) {
      await _keys.deleteServerKey();
    } else {
      await _keys.writeServerKey(settings.key);
    }
  }

  /// Points [ServerConfig] at what [settings] describe. The dev server is
  /// only used with developer mode on; otherwise the app is on Live.
  static void apply(ServerSettings settings, {required bool developerMode}) {
    if (developerMode && settings.devActive) {
      ServerConfig.useDev(key: settings.key);
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
      // The keystore is only read when the dev server was chosen at all.
      if (!developerMode || !_devChosen(box.get(settingsKey))) {
        ServerConfig.useLive();
        return;
      }
      apply(await load(box), developerMode: developerMode);
      debugLog('[SERVER] Using ${ServerConfig.isDev ? 'the dev server '
          '${ServerConfig.baseDomain}' : 'Live'}');
    } catch (e) {
      ServerConfig.useLive();
      debugWarn('[SERVER] Could not read the server choice '
          '(${e.runtimeType}), using Live');
    }
  }
}
