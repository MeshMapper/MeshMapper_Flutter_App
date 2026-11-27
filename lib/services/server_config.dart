import 'package:flutter/foundation.dart';

/// The one place that knows which MeshMapper server the app talks to.
///
/// Every address the app builds (the main site, a region's host, the portal,
/// the debug upload) is derived here from ONE base domain, and the app key
/// sent with a request is chosen here too. Nothing else under `lib/` writes
/// the domain or reads the build-time key: `test/server_domain_guard_test.dart`
/// fails when a file does.
///
/// The default is Live. A custom server is a developer setting (Developer
/// Tools) and is only active when both a valid host name and a key were
/// given. The two keys never cross: while a custom server is active
/// [apiKey] is the custom key and nothing else, and on Live it is the
/// build-time key and nothing else.
///
/// Paths are the same on every server; see `docs/APP_API.md` in the Server
/// repo for the contract.
class ServerConfig {
  ServerConfig._();

  /// The live site's base domain. The only place it is written.
  static const String liveDomain = 'meshmapper.net';

  /// Injected at build time via `--dart-define=API_KEY=...`. Valid on Live
  /// only.
  static const String _buildApiKey = String.fromEnvironment('API_KEY');

  static String? _customDomain;
  static String? _customKey;
  static String? _buildKeyForTest;

  /// Bumped on every change of server, so a listener can tell one happened.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// True while a custom server is active.
  static bool get isCustom => _customDomain != null;

  /// Base domain of the active server: [liveDomain] unless a custom one is on.
  static String get baseDomain => _customDomain ?? liveDomain;

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
  static String get apiKey =>
      _customDomain != null ? _customKey! : (_buildKeyForTest ?? _buildApiKey);

  /// Appended to the name of everything stored that belongs to one server.
  /// Empty on Live, so a normal install keeps every key it has today.
  static String get storageSuffix =>
      _customDomain == null ? '' : '@$_customDomain';

  /// [key] as it is stored for the active server.
  static String scoped(String key) => '$key$storageSuffix';

  /// Tag written on a stored record that may only go back to the server it
  /// was recorded on. Null on Live: an untagged record means Live.
  static String? get recordTag => _customDomain;

  /// Whether a stored record carrying [tag] belongs to the active server.
  static bool ownsRecord(String? tag) =>
      (tag == null || tag.isEmpty ? null : tag) == _customDomain;

  /// Returns to the live server.
  static void useLive() {
    if (_customDomain == null) return;
    _customDomain = null;
    _customKey = null;
    revision.value++;
  }

  /// Activates a custom server. Returns false, changing nothing, unless
  /// [domain] is a usable host name and [key] is not blank.
  static bool useCustom({required String domain, required String key}) {
    final host = normalizeDomain(domain);
    final trimmedKey = key.trim();
    if (host == null || trimmedKey.isEmpty) return false;
    if (_customDomain == host && _customKey == trimmedKey) return true;
    _customDomain = host;
    _customKey = trimmedKey;
    revision.value++;
    return true;
  }

  static final RegExp _label = RegExp(r'^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$');
  static final RegExp _alphaLabel = RegExp(r'^[a-z]{2,63}$');

  /// The bare base domain from what was typed, or null when it is not one.
  ///
  /// Accepts `dev.example.org` and `https://dev.example.org` (a trailing
  /// slash is tolerated). Refuses any other scheme, a path, a port, a
  /// username, an IP address, and the live domain itself: a custom key must
  /// never be sent to live.
  static String? normalizeDomain(String input) {
    var host = input.trim().toLowerCase();
    if (host.startsWith('https://')) host = host.substring(8);
    if (host.endsWith('/')) host = host.substring(0, host.length - 1);
    if (host.isEmpty || host.length > 253) return null;
    final labels = host.split('.');
    if (labels.length < 2) return null;
    if (!labels.every(_label.hasMatch)) return null;
    if (!_alphaLabel.hasMatch(labels.last)) return null;
    if (host == liveDomain || host == 'www.$liveDomain') return null;
    return host;
  }

  /// Why [input] is not accepted as a server URL, or null when it is.
  static String? domainProblem(String input) {
    final typed = input.trim().toLowerCase();
    if (typed.isEmpty) return 'Enter the server, for example dev.example.org';
    if (typed.startsWith('http://')) return 'Only https servers are accepted';
    if (normalizeDomain(typed) != null) return null;
    final bare = typed.startsWith('https://') ? typed.substring(8) : typed;
    if (bare == liveDomain ||
        bare == '$liveDomain/' ||
        bare.startsWith('www.$liveDomain')) {
      return 'That is the live server. Choose Live instead';
    }
    return 'Enter a host name only, with no path, port or address';
  }

  /// Tests only: stands in for the build-time key, which is empty under
  /// `flutter test`.
  @visibleForTesting
  static set buildKeyForTest(String? key) => _buildKeyForTest = key;

  /// Tests only: back to Live with no stand-in key.
  @visibleForTesting
  static void resetForTest() {
    _customDomain = null;
    _customKey = null;
    _buildKeyForTest = null;
  }
}
