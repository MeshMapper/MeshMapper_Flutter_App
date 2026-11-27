import 'package:flutter/foundation.dart';

/// The one place that knows which MeshMapper server the app talks to.
///
/// Every address the app builds (the main site, a region's host, the portal,
/// the debug upload) is derived here from ONE base domain, and the app key
/// sent with a request is chosen here too. Nothing else under `lib/` writes
/// the domain or reads the build-time key: `test/server_domain_guard_test.dart`
/// fails when a file does.
///
/// There are exactly two servers, both fixed here: Live (the default) and
/// the dev server. The app cannot be pointed anywhere else. The dev server
/// is a developer setting (Developer Tools) and is only active once its own
/// app key has been entered. The two keys never cross: while the dev server
/// is active [apiKey] is the dev key and nothing else, and on Live it is the
/// build-time key and nothing else.
///
/// Paths are the same on both servers; see `docs/APP_API.md` in the Server
/// repo for the contract.
class ServerConfig {
  ServerConfig._();

  /// The live site's base domain. The only place it is written.
  static const String liveDomain = 'meshmapper.net';

  /// The dev server's base domain. Fixed: it is never typed or stored.
  static const String devDomain = 'dev.$liveDomain';

  /// Injected at build time via `--dart-define=API_KEY=...`. Valid on Live
  /// only.
  static const String _buildApiKey = String.fromEnvironment('API_KEY');

  static String? _devKey;
  static String? _buildKeyForTest;

  /// Bumped on every change of server, so a listener can tell one happened.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// True while the dev server is active.
  static bool get isDev => _devKey != null;

  /// Base domain of the active server: [liveDomain] or [devDomain].
  static String get baseDomain => _devKey != null ? devDomain : liveDomain;

  /// Main site, no trailing slash.
  static String get siteUrl => 'https://$baseDomain';

  /// App API door on the main site: `/wardrive-api.php/<leg>`.
  static String wardriveApiUrl(String leg) => '$siteUrl/wardrive-api.php/$leg';

  /// Host of a region's (or group's) own site, from its code.
  static String regionHost(String code) => '${code.toLowerCase()}.$baseDomain';

  /// A region's site, no trailing slash.
  static String regionUrl(String code) => 'https://${regionHost(code)}';

  /// Host of the account portal.
  static String get portalHost => 'portal.$baseDomain';

  static String get portalUrl => 'https://$portalHost';

  /// Debug-log upload and bug-report door.
  static String get debugSubmitUrl => '$siteUrl/debug/submitdebug.php';

  /// First-run guide on the main site.
  static String get onboardingUrl => '$siteUrl/?onboarding';

  /// The app key to send to the ACTIVE server.
  static String get apiKey => _devKey ?? _buildKeyForTest ?? _buildApiKey;

  /// Appended to the name of everything stored that belongs to one server.
  /// Empty on Live, so a normal install keeps every key it has today.
  static String get storageSuffix => _devKey == null ? '' : '@$devDomain';

  /// [key] as it is stored for the active server.
  static String scoped(String key) => '$key$storageSuffix';

  /// Tag written on a stored record that may only go back to the server it
  /// was recorded on. Null on Live: an untagged record means Live.
  static String? get recordTag => _devKey == null ? null : devDomain;

  /// Whether a stored record carrying [tag] belongs to the active server.
  static bool ownsRecord(String? tag) =>
      (tag == null || tag.isEmpty ? null : tag) == recordTag;

  /// Returns to the live server.
  static void useLive() {
    if (_devKey == null) return;
    _devKey = null;
    revision.value++;
  }

  /// Activates the dev server with its own app [key]. Returns false,
  /// changing nothing, when [key] is blank: the dev server is never used
  /// with the live key.
  static bool useDev({required String key}) {
    final trimmedKey = key.trim();
    if (trimmedKey.isEmpty) return false;
    if (_devKey == trimmedKey) return true;
    _devKey = trimmedKey;
    revision.value++;
    return true;
  }

  /// Tests only: stands in for the build-time key, which is empty under
  /// `flutter test`.
  @visibleForTesting
  static set buildKeyForTest(String? key) => _buildKeyForTest = key;

  /// Tests only: back to Live with no stand-in key.
  @visibleForTesting
  static void resetForTest() {
    _devKey = null;
    _buildKeyForTest = null;
  }
}
