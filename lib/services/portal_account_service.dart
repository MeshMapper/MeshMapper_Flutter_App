import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../utils/constants.dart';
import '../utils/debug_logger_io.dart';
import '../utils/pkce.dart';
import 'portal_token_store.dart';

/// The MyMeshMapper portal wire contract.
///
/// Mirror of `MeshMapper_Server/docs/SPEC-app-portal-link.md`. If the server
/// renames a route, a parameter or the host, THIS CLASS is the only thing that
/// has to change.
class PortalApi {
  PortalApi._();

  static const String baseUrl = 'https://portal.meshmapper.net';
  static const String authorizePath = '/portal.php';
  static const String apiPath = '/portal_app_api.php';

  /// Deliberately NOT `meshmapper` — that bare scheme is a documented
  /// clipboard-only format (`docs/CUSTOM_API_ENDPOINT.md`,
  /// `meshmapper://custom-api?...`) and OS-registering it would hijack it.
  static const String callbackScheme = 'meshmapper-auth';
  static const String callbackHost = 'callback';
  static const String redirectUri = '$callbackScheme://$callbackHost';

  static const Duration requestTimeout = Duration(seconds: 10);

  /// A stashed PKCE pair older than this is dead; the portal's own code TTL is
  /// 300s, so 10 minutes is generous and still bounds the window.
  static const Duration pkceTtl = Duration(minutes: 10);

  /// `me` writes the site-wide auth DB, so it is refreshed at most hourly.
  static const Duration meThrottle = Duration(hours: 1);

  static Uri authorizeUrl({
    required String codeChallenge,
    required String state,
  }) =>
      Uri.parse('$baseUrl$authorizePath').replace(queryParameters: {
        'app_authorize': '1',
        'code_challenge': codeChallenge,
        'code_challenge_method': 'S256',
        'redirect_uri': redirectUri,
        'state': state,
      });

  /// `?action=` is the primary router; PATH_INFO is not used.
  static Uri action(String name) =>
      Uri.parse('$baseUrl$apiPath').replace(queryParameters: {'action': name});
}

/// The signed-in portal identity.
class PortalAccount {
  final int id;
  final String username;
  final String displayName;

  const PortalAccount({
    required this.id,
    required this.username,
    required this.displayName,
  });

  /// Parses the API shape `{id, username, display_name}`. `display_name` is a
  /// lazily-added nullable column server-side, so it coalesces to `username`.
  static PortalAccount? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final id = (json['id'] as num?)?.toInt();
    final username = json['username'];
    if (id == null || username is! String || username.isEmpty) return null;
    final display = json['display_name'];
    return PortalAccount(
      id: id,
      username: username,
      displayName:
          (display is String && display.isNotEmpty) ? display : username,
    );
  }

  /// Hive cache shape (`portal_account_info`).
  Map<String, dynamic> toCache() => {
        'user_id': id,
        'username': username,
        'display_name': displayName,
      };

  static PortalAccount? fromCache(Map<dynamic, dynamic>? cache) {
    if (cache == null) return null;
    final id = (cache['user_id'] as num?)?.toInt();
    final username = cache['username'];
    if (id == null || username is! String || username.isEmpty) return null;
    final display = cache['display_name'];
    return PortalAccount(
      id: id,
      username: username,
      displayName:
          (display is String && display.isNotEmpty) ? display : username,
    );
  }
}

/// One HTTP answer from the portal's machine lane.
class _PortalResponse {
  /// 0 means no HTTP response at all (timeout, DNS, socket).
  final int status;
  final Map<String, dynamic> json;

  /// The value of `{"error": "..."}` when the body carried one.
  final String? error;

  const _PortalResponse(this.status, this.json, this.error);

  bool get ok => status >= 200 && status < 300 && json['ok'] == true;
  bool get networkFailure => status == 0;
}

/// The MyMeshMapper portal lane.
///
/// Deliberately separate from `ApiService`: different host, different auth
/// model (long-lived bearer vs. per-session geo-auth), different body encoding
/// (form vs. JSON). Nothing here may block or fail a wardriving connection.
class PortalAccountService {
  final http.Client _client;
  final PortalTokenStore _store;
  final AppLinks? _appLinks;
  final Future<bool> Function(Uri uri) _launcher;

  String? _token;
  PortalAccount? _account;
  PendingPkce? _pendingPkce;
  String? _lastCode;
  StreamSubscription<Uri>? _linkSub;

  /// Codes already exchanged this app session (dedupe — see handleAuthCallback).
  final Set<String> _consumedCodes = {};

  /// Optional friendly label sent with `token` and `link` (device name).
  String? Function()? deviceLabelProvider;

  /// Fired whenever the cached identity or linked-device list changes.
  void Function()? onAccountChanged;

  /// Fired on sign-out. `reason` is `token_invalid` or `user`.
  void Function(String reason)? onSignedOut;

  /// Fired once per completed sign-in attempt.
  void Function(bool success, String? errorCode)? onSignInComplete;

  PortalAccountService({
    http.Client? client,
    PortalTokenStore? store,
    AppLinks? appLinks,
    Future<bool> Function(Uri uri)? launcher,
  })  : _client = client ?? http.Client(),
        _store = store ?? SecureTokenStore(),
        _appLinks = appLinks,
        _launcher = launcher ?? _launchExternally;

  /// `externalApplication` is load-bearing: an in-app WebView would see the
  /// user's portal password, which is exactly what this design avoids.
  static Future<bool> _launchExternally(Uri uri) =>
      launchUrl(uri, mode: LaunchMode.externalApplication);

  bool get isSignedIn => _token != null;
  PortalAccount? get account => _account;

  /// Restore the identity cached in Hive so the UI has a name before any
  /// network call happens.
  void hydrateAccount(PortalAccount account) => _account = account;

  Future<void> init() async {
    _token = await _store.readToken();
    _log('init: signedIn=${_token != null}');

    final links = _appLinks;
    if (links == null) {
      _log('init: deep links not wired (web or test)');
      return;
    }

    // Subscribe FIRST. In app_links 6.x uriLinkStream carries the cold-start
    // link as well as later ones, so a late subscription can miss it outright.
    _linkSub = links.uriLinkStream.listen(
      (uri) => unawaited(handleAuthCallback(uri)),
      onError: (Object e) => _warn('link stream error: ${e.runtimeType}'),
    );

    try {
      final initial = await links.getInitialLink();
      if (initial != null) await handleAuthCallback(initial);
    } catch (e) {
      _warn('getInitialLink failed: ${e.runtimeType}');
    }
  }

  /// Re-check the last deep link on app resume — iOS can deliver the callback
  /// while the Dart isolate is suspended.
  Future<void> checkLinkOnResume() async {
    final links = _appLinks;
    if (links == null) return;
    try {
      final latest = await links.getLatestLink();
      if (latest != null) await handleAuthCallback(latest);
    } catch (e) {
      _warn('getLatestLink failed: ${e.runtimeType}');
    }
  }

  Future<bool> beginSignIn() async {
    final pkce = PkcePair.generate();
    final pending = PendingPkce(
      verifier: pkce.verifier,
      state: pkce.state,
      createdAt: DateTime.now(),
    );
    _pendingPkce = pending;
    await _store.writePendingPkce(pending);

    final url = PortalApi.authorizeUrl(
      codeChallenge: pkce.challenge,
      state: pkce.state,
    );
    _log('opening the portal consent page (${url.host}${url.path})');
    try {
      final launched = await _launcher(url);
      if (!launched) _warn('the system browser refused the authorize URL');
      return launched;
    } catch (e) {
      _err('could not open the authorize URL: ${e.runtimeType}');
      return false;
    }
  }

  /// Handle one inbound deep link. Anything that is not our callback is
  /// silently ignored — other schemes belong to other features.
  Future<void> handleAuthCallback(Uri uri) async {
    if (uri.scheme != PortalApi.callbackScheme ||
        uri.host != PortalApi.callbackHost) {
      return;
    }
    // Query stripped on purpose: it carries the code and the state.
    _log('callback received: ${uri.scheme}://${uri.host}${uri.path}');

    final error = uri.queryParameters['error'];
    if (error != null && error.isNotEmpty) {
      _log('callback carried error=$error — clearing the pending pair');
      _pendingPkce = null;
      await _store.deletePendingPkce();
      onSignInComplete?.call(false, error);
      return;
    }

    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];
    if (code == null || code.isEmpty || state == null || state.isEmpty) {
      _warn('callback missing code or state — ignoring');
      return;
    }

    // app_links 6.x can deliver the same cold-start URI twice (getInitialLink
    // AND uriLinkStream) and can deliver both CONCURRENTLY — init() runs the
    // stream listener unawaited while getInitialLink() is still in flight. The
    // portal burns a code on first use, so a second exchange fails with
    // code_invalid and looks like a broken sign-in.
    //
    // `Set.add` is the atomic test-and-set, and it has to happen HERE: every
    // later checkpoint sits behind `await _store.readPendingPkce()`, and an
    // await between the test and the insert lets both deliveries through. The
    // claim is released again on each path below that decides not to exchange.
    if (!_consumedCodes.add(code)) {
      _log('callback duplicate — this code was already exchanged');
      return;
    }

    final pending = _pendingPkce ?? await _store.readPendingPkce();
    if (pending == null) {
      _consumedCodes.remove(code);
      _warn('callback with no pending PKCE pair — ignoring');
      return;
    }
    if (DateTime.now().difference(pending.createdAt) > PortalApi.pkceTtl) {
      _consumedCodes.remove(code);
      _warn('callback pending pair expired — discarding');
      _pendingPkce = null;
      await _store.deletePendingPkce();
      return;
    }
    if (pending.state != state) {
      // Do NOT burn the pair, and release the code: the genuine callback may
      // still be coming and may legitimately carry this very code.
      _consumedCodes.remove(code);
      _warn('callback state mismatch — ignoring');
      return;
    }

    // Burn the pair BEFORE the exchange: one attempt per authorize. The code
    // itself was already claimed by the atomic add above.
    _pendingPkce = null;
    await _store.deletePendingPkce();

    _lastCode = code;
    try {
      await _exchangeCode(code: code, verifier: pending.verifier);
    } finally {
      _lastCode = null;
    }
  }

  Future<void> _exchangeCode({
    required String code,
    required String verifier,
  }) async {
    final label = deviceLabelProvider?.call();
    final response = await _post(
      'token',
      {
        'code': code,
        'code_verifier': verifier,
        if (label != null && label.isNotEmpty) 'device_label': label,
      },
      authenticated: false,
    );

    if (!response.ok) {
      _warn('token exchange failed (status=${response.status}, '
          'error=${response.error ?? 'none'})');
      onSignInComplete?.call(false, response.error ?? 'network');
      return;
    }

    final token = response.json['token'];
    final account =
        PortalAccount.fromJson(response.json['user'] as Map<String, dynamic>?);
    if (token is! String || token.isEmpty || account == null) {
      _warn('token exchange returned an unusable body');
      onSignInComplete?.call(false, 'bad_response');
      return;
    }

    _token = token;
    _account = account;
    await _store.writeToken(token);
    _log('signed in as ${account.username} (id=${account.id})');
    onAccountChanged?.call();
    onSignInComplete?.call(true, null);
  }

  Future<_PortalResponse> _post(
    String action,
    Map<String, String> body, {
    bool authenticated = true,
  }) =>
      _postWithToken(action, body, authenticated ? _token : null);

  Future<_PortalResponse> _postWithToken(
    String action,
    Map<String, String> body,
    String? token,
  ) async {
    final headers = <String, String>{
      'Content-Type': 'application/x-www-form-urlencoded; charset=utf-8',
      'Accept': 'application/json',
      'User-Agent': AppConstants.userAgent,
    };
    if (token != null) {
      // Dual-send: Apache/FPM drops Authorization without CGIPassAuth, and the
      // custom header is the proven-to-arrive fallback on this stack.
      headers['Authorization'] = 'Bearer $token';
      headers['X-MM-App-Token'] = token;
    }

    try {
      final response = await _client
          .post(PortalApi.action(action), headers: headers, body: body)
          .timeout(PortalApi.requestTimeout);

      var json = const <String, dynamic>{};
      try {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic>) json = decoded;
      } catch (_) {
        // Captive portal HTML / WAF block page — opaque, not an API answer.
      }
      final error = json['error'] is String ? json['error'] as String : null;
      return _PortalResponse(response.statusCode, json, error);
    } on TimeoutException {
      _warn('$action timed out after ${PortalApi.requestTimeout.inSeconds}s');
      return const _PortalResponse(0, {}, 'timeout');
    } catch (e) {
      _warn('$action network failure: ${e.runtimeType}');
      return const _PortalResponse(0, {}, 'network');
    }
  }

  /// Drop local credentials. Called for an explicit sign-out and for the one
  /// server answer that means "this token is dead": 401 + `token_invalid`.
  Future<void> _forceSignOut(String reason) async {
    _token = null;
    _account = null;
    await _store.deleteToken();
    await _store.deletePendingPkce();
    _pendingPkce = null;
    _log('signed out ($reason)');
    onSignedOut?.call(reason);
    onAccountChanged?.call();
  }

  /// 8-char uppercase prefix — full public keys never reach a log.
  String _pk(String? pubkey) {
    if (pubkey == null || pubkey.isEmpty) return 'none';
    final upper = pubkey.toUpperCase();
    return upper.length <= 8 ? upper : upper.substring(0, 8);
  }

  void _log(String message) => debugLog('[ACCOUNT] ${_redact(message)}');
  void _warn(String message) => debugWarn('[ACCOUNT] ${_redact(message)}');
  void _err(String message) => debugError('[ACCOUNT] ${_redact(message)}');

  static final RegExp _bearerPattern =
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]{8,}');

  /// Mechanical backstop on top of "never interpolate a secret". Debug logging
  /// is ON in release builds and log files are uploaded verbatim with bug
  /// reports, so discipline alone WILL eventually leak.
  String _redact(String message) {
    var out = message;
    for (final secret in _liveSecrets) {
      if (secret.length >= 8 && out.contains(secret)) {
        out = out.replaceAll(secret, '<redacted>');
      }
    }
    return out.replaceAll(_bearerPattern, 'Bearer <redacted>');
  }

  Iterable<String> get _liveSecrets sync* {
    final token = _token;
    if (token != null) yield token;
    final pending = _pendingPkce;
    if (pending != null) {
      yield pending.verifier;
      yield pending.state;
    }
    final code = _lastCode;
    if (code != null) yield code;
  }

  void dispose() {
    _linkSub?.cancel();
    _linkSub = null;
    _client.close();
  }
}
