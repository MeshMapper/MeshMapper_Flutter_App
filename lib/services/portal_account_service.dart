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

  /// Every 429 on this lane carries `Retry-After` in delta-seconds, but a
  /// proxy can strip it or rewrite it as an HTTP-date. This is what an
  /// unusable header costs.
  static const Duration defaultRetryAfter = Duration(minutes: 5);

  /// Ceiling for a server-supplied backoff. The longest the portal sends is
  /// 600s, so anything past an hour is a broken header, not an instruction.
  static const Duration maxRetryAfter = Duration(hours: 1);

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

/// One companion radio bound to the account (`me` → `pubkeys[]`).
class LinkedPubkey {
  final String pubkey; // UPPER 64-hex
  final String label;
  final String name;
  final int points;

  const LinkedPubkey({
    required this.pubkey,
    required this.label,
    required this.name,
    required this.points,
  });

  static LinkedPubkey? fromJson(Map<String, dynamic> json) {
    final pubkey = json['pubkey'];
    if (pubkey is! String || pubkey.isEmpty) return null;
    return LinkedPubkey(
      pubkey: pubkey.toUpperCase(),
      label: json['label'] is String ? json['label'] as String : '',
      name: json['name'] is String ? json['name'] as String : '',
      points: (json['points'] as num?)?.toInt() ?? 0,
    );
  }

  /// Hive cache shape (`portal_companions`).
  Map<String, dynamic> toCache() => {
        'pubkey': pubkey,
        'label': label,
        'name': name,
        'points': points,
      };

  /// Hive hands back `Map<dynamic, dynamic>`, hence the loose parameter type.
  static LinkedPubkey? fromCache(Map<dynamic, dynamic> cache) {
    final pubkey = cache['pubkey'];
    if (pubkey is! String || pubkey.isEmpty) return null;
    final points = cache['points'];
    return LinkedPubkey(
      pubkey: pubkey.toUpperCase(),
      label: cache['label'] is String ? cache['label'] as String : '',
      name: cache['name'] is String ? cache['name'] as String : '',
      points: points is num ? points.toInt() : 0,
    );
  }
}

/// One award the portal granted to any of the account's companions.
class PortalAward {
  final String name;
  final String description;

  const PortalAward({required this.name, required this.description});

  /// Wire and cache share one shape: `{name, description}`. An award without
  /// a name is dropped, a missing description reads as empty.
  static PortalAward? fromJson(Map<dynamic, dynamic> json) {
    final name = json['name'];
    if (name is! String || name.isEmpty) return null;
    final description = json['description'];
    return PortalAward(
      name: name,
      description: description is String ? description : '',
    );
  }

  Map<String, dynamic> toCache() => {'name': name, 'description': description};
}

/// The account-wide totals the portal's Overview tab shows (`me` -> `overview`).
///
/// The server sums points over each companion's primary, exactly as the
/// portal does, so a radio filed under a group counts once. The app never adds
/// up the per-companion points itself: that sum is wrong for grouped radios.
class PortalOverview {
  final int points;
  final int weekly;
  final int grid;
  final List<PortalAward> awards;

  const PortalOverview({
    required this.points,
    required this.weekly,
    required this.grid,
    required this.awards,
  });

  /// Null when the block is missing or not an object. An older server does
  /// not send it, and the UI hides the card rather than printing zeros.
  ///
  /// Type CHECKS, not casts: the same hostile-shape guard the token exchange
  /// uses. A string where a number belongs reads as zero.
  static PortalOverview? fromJson(Object? json) {
    if (json is! Map) return null;
    final rawAwards = json['awards'];
    return PortalOverview(
      points: _int(json['points']),
      weekly: _int(json['weekly']),
      grid: _int(json['grid']),
      awards: rawAwards is List
          ? rawAwards
              .whereType<Map>()
              .map(PortalAward.fromJson)
              .whereType<PortalAward>()
              .toList(growable: false)
          : const [],
    );
  }

  static int _int(Object? value) => value is num ? value.toInt() : 0;

  /// Hive cache shape (`portal_overview`), the same keys as the wire.
  Map<String, dynamic> toCache() => {
        'points': points,
        'weekly': weekly,
        'grid': grid,
        'awards': awards.map((award) => award.toCache()).toList(),
      };

  static PortalOverview? fromCache(Object? cache) => fromJson(cache);
}

/// Outcome of an `action=link` POST.
sealed class LinkResult {
  const LinkResult();
}

class LinkSuccess extends LinkResult {
  final String pubkey;

  /// True when the server answered `already:true` (idempotent relink).
  final bool already;

  const LinkSuccess({required this.pubkey, required this.already});
}

/// The pubkey belongs to a different account. `UNIQUE(pubkey)` means this is
/// permanent until the other owner unlinks — never retry it silently.
class LinkAlreadyLinkedOtherAccount extends LinkResult {
  const LinkAlreadyLinkedOtherAccount();
}

/// The account still holds placeholder devices. The app lane NEVER adopts —
/// adoption is irreversible and belongs in the browser portal.
class LinkAdoptionRequired extends LinkResult {
  final int devices;
  const LinkAdoptionRequired(this.devices);
}

class LinkUnauthorized extends LinkResult {
  const LinkUnauthorized();
}

class LinkNetworkError extends LinkResult {
  final String detail;
  const LinkNetworkError(this.detail);
}

class LinkServerError extends LinkResult {
  final String code;
  final int statusCode;
  const LinkServerError(this.code, this.statusCode);
}

/// How a link attempt should be presented. Returned by `AppStateProvider`, not
/// by the service — the provider folds persistence and backoff into it.
enum PortalLinkStatus {
  skipped,
  linked,
  adoptionRequired,
  alreadyLinkedOtherAccount,
  unauthorized,
  failed,
}

class PortalLinkOutcome {
  final PortalLinkStatus status;
  final int adoptionDeviceCount;
  final String? accountName;

  /// How long the portal asked us to stay off the link lane, when that is why
  /// this attempt did not happen. Null for every other outcome.
  final Duration? retryAfter;

  const PortalLinkOutcome(
    this.status, {
    this.adoptionDeviceCount = 0,
    this.accountName,
    this.retryAfter,
  });
}

/// One HTTP answer from the portal's machine lane.
class _PortalResponse {
  /// 0 means no HTTP response at all (timeout, DNS, socket).
  final int status;
  final Map<String, dynamic> json;

  /// The value of `{"error": "..."}` when the body carried one.
  final String? error;

  /// The `Retry-After` a 429 carried, already parsed and clamped. Null on
  /// every answer that was not rate limited.
  final Duration? retryAfter;

  const _PortalResponse(this.status, this.json, this.error, {this.retryAfter});

  bool get ok => status >= 200 && status < 300 && json['ok'] == true;
  bool get networkFailure => status == 0;

  /// Terminal on this lane: the portal never softens a 429 on a retry, it
  /// re-arms the block (see [PortalAccountService.rateLimitBackoff]).
  bool get rateLimited => status == 429;
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
  List<LinkedPubkey> _linkedPubkeys = const [];
  PortalOverview? _overview;
  DateTime? _lastMeAt;
  PendingPkce? _pendingPkce;
  String? _lastCode;
  StreamSubscription<Uri>? _linkSub;

  /// Codes already exchanged this app session (dedupe — see handleAuthCallback).
  final Set<String> _consumedCodes = {};

  /// States whose `error=` callback has already been honoured this session
  /// (dedupe — see _handleErrorCallback).
  final Set<String> _consumedErrorStates = {};

  /// Route -> earliest time that route may be called again. Filled from a
  /// 429's `Retry-After`. In-memory: a restart is a fresh start, and the
  /// server re-answers 429 if the block is still live.
  final Map<String, DateTime> _rateLimitedUntil = {};

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
  List<LinkedPubkey> get linkedPubkeys => List.unmodifiable(_linkedPubkeys);

  /// Account-wide totals from the last `me`, or null when unknown: never
  /// fetched, signed out, or a server that does not send the block yet.
  PortalOverview? get overview => _overview;

  /// Restore the identity cached in Hive so the UI has a name before any
  /// network call happens.
  void hydrateAccount(PortalAccount account) => _account = account;

  /// Restore the cached linked-device list from Hive.
  ///
  /// Load-bearing: `link`/`unlink` mutate THIS list and the provider mirrors it
  /// back wholesale on `onAccountChanged`. Without the hydrate, linking a new
  /// radio would publish a one-entry list and wipe every previously cached
  /// pubkey. Only membership is restored — label/name/points are `me` data and
  /// are refilled by the next `refreshMe`. Deliberately does NOT fire
  /// `onAccountChanged`: this runs during load, before any listener cares.
  void hydrateLinkedPubkeys(List<String> pubkeys) => hydrateLinkedCompanions(
        pubkeys
            .where((pubkey) => pubkey.isNotEmpty)
            .map((pubkey) => LinkedPubkey(
                  pubkey: pubkey.toUpperCase(),
                  label: '',
                  name: '',
                  points: 0,
                ))
            .toList(growable: false),
      );

  /// Restore the cached companions WITH label, name and points, so the
  /// Account page is filled on a cold start. Same load-bearing role as
  /// [hydrateLinkedPubkeys] (which now delegates here) and, like it, does NOT
  /// fire `onAccountChanged`.
  void hydrateLinkedCompanions(List<LinkedPubkey> companions) {
    _linkedPubkeys = companions
        .where((companion) => companion.pubkey.isNotEmpty)
        .toList(growable: false);
  }

  /// Restore the cached overview from Hive. Does NOT fire `onAccountChanged`.
  void hydrateOverview(PortalOverview? overview) => _overview = overview;

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

    // Fire-and-forget on purpose. The caller AWAITS init() during app startup,
    // and handleAuthCallback runs a token exchange with a 10s timeout — that is
    // the feature's own cold-start path, and awaiting it here would stall BLE
    // setup and auto-connect behind it. The token read and the stream subscribe
    // above are the only parts startup actually has to wait for.
    unawaited(links.getInitialLink().then<void>((initial) async {
      if (initial != null) await handleAuthCallback(initial);
    }).catchError((Object e) {
      _warn('getInitialLink failed: ${e.runtimeType}');
    }));
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
    final code = uri.queryParameters['code'];
    final state = uri.queryParameters['state'];
    final hasError = error != null && error.isNotEmpty;

    // `state` is what ties any callback — success OR failure — to an attempt
    // this app actually started.
    if (state == null || state.isEmpty) {
      _warn('callback missing state — ignoring');
      return;
    }

    if (hasError) {
      await _handleErrorCallback(error, state);
      return;
    }

    if (code == null || code.isEmpty) {
      _warn('callback missing code — ignoring');
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
    // Arm the redactor. On a cold start the pair comes off disk and
    // `_pendingPkce` would otherwise stay null, leaving `_liveSecrets` empty —
    // the backstop would be inert for the rest of this flow, which is exactly
    // the stretch that handles the verifier and the token.
    _pendingPkce = pending;

    if (DateTime.now().difference(pending.createdAt) > PortalApi.pkceTtl) {
      _consumedCodes.remove(code);
      _warn('callback pending pair expired — discarding');
      _pendingPkce = null;
      await _store.deletePendingPkce();
      // A real attempt was live and just died; the UI must stop waiting.
      onSignInComplete?.call(false, 'expired');
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
    } catch (e) {
      // handleAuthCallback is driven unawaited from the uriLinkStream listener,
      // so anything escaping here is an unhandled zone error: the attempt would
      // die silently with the code already claimed and the UI still spinning.
      _err('token exchange crashed: ${e.runtimeType}');
      onSignInComplete?.call(false, 'bad_response');
    } finally {
      _lastCode = null;
    }
  }

  /// Handle a callback that reported `error=`.
  ///
  /// A deep link is unauthenticated — ANY app on the device can fire
  /// `meshmapper-auth://callback?error=x`. Honouring that blindly let a foreign
  /// app destroy a legitimate in-flight pair (a sign-in DoS) and push an
  /// arbitrary string into the completion callback. So an error is believed
  /// only when it answers a sign-in this app actually started: a live pending
  /// pair whose state matches. Everything else is dropped without a trace of
  /// the attacker's string.
  Future<void> _handleErrorCallback(String error, String state) async {
    // Same atomic test-and-set as the code path, keyed on the state. Sequential
    // dedupe falls out of the pair being burned, but two CONCURRENT deliveries
    // both park on the store read below and would both fire onSignInComplete.
    // The claim is released again on every path that decides not to honour it.
    if (!_consumedErrorStates.add(state)) {
      _log('callback duplicate — this attempt was already declined');
      return;
    }

    final PendingPkce? pending;
    try {
      pending = _pendingPkce ?? await _store.readPendingPkce();
    } catch (e) {
      _consumedErrorStates.remove(state);
      _err('reading the pending pair for a declined sign-in failed: '
          '${e.runtimeType}');
      return;
    }
    if (pending == null) {
      _consumedErrorStates.remove(state);
      _warn('callback reported an error with no sign-in in flight — ignoring');
      return;
    }
    _pendingPkce = pending;
    if (pending.state != state) {
      // Leave the pair alone: the genuine callback may still be coming.
      _consumedErrorStates.remove(state);
      _warn('callback reported an error for a different attempt — ignoring');
      return;
    }

    _pendingPkce = null;
    try {
      await _store.deletePendingPkce();
    } catch (e) {
      // Not fatal — the pair is dead in memory and the stored copy carries a
      // TTL. What must NOT happen is this escaping as a zone error on the
      // unawaited uriLinkStream path, leaving the UI spinning on a sign-in
      // that has already been refused.
      _warn('clearing the declined pending pair failed: ${e.runtimeType}');
    }
    final reason = _sanitizeErrorCode(error);
    _log('the portal declined the sign-in (reason=$reason)');
    onSignInComplete?.call(false, reason);
  }

  /// The portal's error codes are lowercase snake_case (`access_denied`).
  /// Anything else came from something that is not the portal, so it is
  /// collapsed to a fixed token rather than forwarded to the UI or a log.
  static String _sanitizeErrorCode(String raw) =>
      _errorCodePattern.hasMatch(raw) ? raw : 'denied';

  static final RegExp _errorCodePattern = RegExp(r'^[a-z_]{1,32}$');

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
    // Type CHECK, not a cast: `"user": []` or `"user": "bob"` would throw a
    // TypeError out of an unawaited future. fromJson's null path already
    // reports this as an unusable body.
    final rawUser = response.json['user'];
    final account = PortalAccount.fromJson(
        rawUser is Map<String, dynamic> ? rawUser : null);
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

    // The exchange carries the identity but NOT the pubkeys, so the account
    // card would sit at "0 device(s) on this account" until the next radio
    // connect happened to run `me`. Pull the list now so a fresh sign-in shows
    // the user it worked. Deliberately AFTER the callbacks above: the sign-in
    // is already a success, and a failed list must not colour it.
    await refreshMe();
  }

  /// True only for the one answer that means "this token is dead". A bare 401
  /// (captive portal, WAF) must NOT sign the user out.
  bool _isTokenInvalid(_PortalResponse response) =>
      response.status == 401 && response.error == 'token_invalid';

  /// How long the portal has told us to stay off [action], or null when that
  /// route is clear.
  ///
  /// Worth honouring precisely: the server's buckets slide, and a request made
  /// while blocked does NOT reset the count, it re-arms a FRESH penalty. A
  /// client that keeps knocking extends its own lockout indefinitely.
  Duration? rateLimitBackoff(String action) {
    final until = _rateLimitedUntil[action];
    if (until == null) return null;
    final left = until.difference(DateTime.now());
    if (left > Duration.zero) return left;
    _rateLimitedUntil.remove(action);
    return null;
  }

  /// The longest live block across the two routes one link attempt walks.
  /// Either one blocked means the attempt cannot finish.
  Duration? get linkLaneBackoff {
    final nonce = rateLimitBackoff('nonce');
    final link = rateLimitBackoff('link');
    if (nonce == null) return link;
    if (link == null) return nonce;
    return nonce > link ? nonce : link;
  }

  /// `Retry-After` is delta-seconds on this lane. An HTTP-date is legal HTTP
  /// and useless here, so anything that is not a sane integer falls back to
  /// [PortalApi.defaultRetryAfter] rather than to no backoff at all.
  static Duration _parseRetryAfter(String? raw) {
    final seconds = int.tryParse(raw?.trim() ?? '');
    if (seconds == null || seconds <= 0) return PortalApi.defaultRetryAfter;
    final backoff = Duration(seconds: seconds);
    return backoff > PortalApi.maxRetryAfter
        ? PortalApi.maxRetryAfter
        : backoff;
  }

  /// Ask the portal for a fresh 32-byte challenge bound to [pubkeyHex].
  /// Returns the 64-hex nonce, or null on any failure (never throws).
  Future<String?> requestNonce(String pubkeyHex) async {
    final response = await _post('nonce', {'pubkey': pubkeyHex.toUpperCase()});
    if (_isTokenInvalid(response)) {
      await _forceSignOut('token_invalid');
      return null;
    }
    // The nonce route answers {nonce, expires_at} with no `ok` flag.
    final nonce = response.json['nonce'];
    if (response.status >= 200 &&
        response.status < 300 &&
        nonce is String &&
        _noncePattern.hasMatch(nonce)) {
      _log('nonce issued for ${_pk(pubkeyHex)}');
      return nonce;
    }
    _warn('nonce request failed for ${_pk(pubkeyHex)} '
        '(status=${response.status}, error=${response.error ?? 'none'})');
    return null;
  }

  static final RegExp _noncePattern = RegExp(r'^[0-9a-fA-F]{64}$');

  /// Post the radio's Ed25519 signature over the raw nonce bytes.
  Future<LinkResult> linkDevice({
    required String pubkey,
    required String nonce,
    required String signature,
    String? label,
  }) async {
    final upper = pubkey.toUpperCase();
    final response = await _post('link', {
      'pubkey': upper,
      'nonce': nonce,
      'signature': signature,
      if (label != null && label.isNotEmpty) 'label': label,
    });

    if (_isTokenInvalid(response)) {
      await _forceSignOut('token_invalid');
      return const LinkUnauthorized();
    }
    if (response.status == 401) {
      return const LinkNetworkError('bare 401 (captive portal?)');
    }
    if (response.networkFailure) {
      return LinkNetworkError(response.error ?? 'network');
    }
    if (response.ok) {
      final already = response.json['already'] == true;
      _log('link ok for ${_pk(upper)} (already=$already)');
      if (!_linkedPubkeys.any((p) => p.pubkey == upper)) {
        _linkedPubkeys = [
          ..._linkedPubkeys,
          LinkedPubkey(
            pubkey: upper,
            label: label ?? '',
            name: response.json['name'] is String
                ? response.json['name'] as String
                : '',
            points: (response.json['points'] as num?)?.toInt() ?? 0,
          ),
        ];
        onAccountChanged?.call();
      }
      return LinkSuccess(pubkey: upper, already: already);
    }

    switch (response.error) {
      case 'already_linked':
        _log('link refused for ${_pk(upper)}: owned by another account');
        return const LinkAlreadyLinkedOtherAccount();
      case 'adoption_required':
        final devices = (response.json['devices'] as num?)?.toInt() ?? 0;
        _log('link needs browser adoption first '
            '($devices placeholder device(s))');
        return LinkAdoptionRequired(devices);
      default:
        _warn('link failed for ${_pk(upper)} '
            '(status=${response.status}, error=${response.error ?? 'none'})');
        return LinkServerError(response.error ?? 'unknown', response.status);
    }
  }

  /// In-app recovery for a mislink — without it a phone mistake needs a laptop.
  Future<bool> unlinkDevice(String pubkey) async {
    final upper = pubkey.toUpperCase();
    final response = await _post('unlink', {'pubkey': upper});
    if (_isTokenInvalid(response)) {
      await _forceSignOut('token_invalid');
      return false;
    }
    if (!response.ok) {
      _warn('unlink failed for ${_pk(upper)} (status=${response.status})');
      return false;
    }
    _linkedPubkeys =
        _linkedPubkeys.where((p) => p.pubkey != upper).toList(growable: false);
    _log('unlinked ${_pk(upper)}');
    onAccountChanged?.call();
    return true;
  }

  /// Refresh the identity and the linked-device list.
  ///
  /// Throttled to once an hour: the bearer gate touches the SITE-WIDE auth DB
  /// on every call, so a chatty client writes it on every reconnect.
  Future<bool> refreshMe({bool force = false}) async {
    if (_token == null) return false;

    // `force` skips the LOCAL throttle, never a backoff the server asked for.
    // The `me` bucket is 12/hour with a 600s rolling penalty, so a user
    // tapping Refresh past the cap would extend their own lockout with every
    // tap.
    final blocked = rateLimitBackoff('me');
    if (blocked != null) {
      _log('me: rate limited, ${blocked.inSeconds}s left');
      return false;
    }

    final last = _lastMeAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last) < PortalApi.meThrottle) {
      _log('me: throttled');
      return false;
    }
    _lastMeAt = DateTime.now();

    final response = await _post('me', const {});
    if (_isTokenInvalid(response)) {
      await _forceSignOut('token_invalid');
      return false;
    }
    if (!response.ok) {
      _warn('me failed (status=${response.status}, '
          'error=${response.error ?? 'none'})');
      return false;
    }

    // Type CHECK, not a cast — same hostile shape the token exchange guards
    // against (`"user": []` would throw a TypeError out of a plain cast).
    final rawUser = response.json['user'];
    final account = PortalAccount.fromJson(
        rawUser is Map<String, dynamic> ? rawUser : null);
    if (account != null) _account = account;

    final raw = response.json['pubkeys'];
    if (raw is List) {
      _linkedPubkeys = raw
          .whereType<Map>()
          .map((entry) => LinkedPubkey.fromJson(entry.cast<String, dynamic>()))
          .whereType<LinkedPubkey>()
          .toList(growable: false);
    }
    // Absent on a server that predates the block. Null hides the card; it
    // never prints zeros for an account that may well have points.
    _overview = PortalOverview.fromJson(response.json['overview']);
    final overview = _overview;
    _log('me ok: ${_linkedPubkeys.length} linked device(s), overview='
        '${overview == null ? 'absent' : '${overview.points} pts, '
            '${overview.grid} squares, ${overview.awards.length} award(s)'}');
    onAccountChanged?.call();
    return true;
  }

  /// Sign out. The LOCAL clear always happens; the server revoke is best-effort
  /// with a single retry, because a live server-side token with no local copy
  /// is an orphan the user cannot revoke from the app.
  Future<void> logout() async {
    final token = _token;
    await _forceSignOut('user');
    if (token == null) return;

    final first = await _postWithToken('logout', const {}, token);
    if (first.ok) {
      _log('logout: server token revoked');
      return;
    }
    if (first.rateLimited) {
      // The retry would land inside the block and re-arm it. The orphaned
      // server token is the accepted trade, same as a failed retry.
      _warn('logout revoke rate limited (retry after '
          '${first.retryAfter?.inSeconds ?? 0}s); the server token stays '
          'until it expires');
      return;
    }
    _warn('logout revoke failed (status=${first.status}) — retrying once');
    final retry = await _postWithToken('logout', const {}, token);
    if (!retry.ok) {
      _warn('logout revoke retry failed (status=${retry.status}); '
          'the server token stays until it expires');
    }
  }

  Future<_PortalResponse> _post(
    String action,
    Map<String, String> body, {
    bool authenticated = true,
  }) {
    // An authenticated call with no token can only ever be refused, and sending
    // it header-less would draw a bare 401 the callers have to disambiguate —
    // worse, a race that signs out mid-link would answer `token_invalid` and
    // fire a SECOND sign-out event. Answer locally instead; `status == 0` makes
    // this a network failure to every caller, which is the harmless verdict.
    if (authenticated && _token == null) {
      _warn('$action skipped: signed out');
      return Future.value(const _PortalResponse(0, {}, 'no_token'));
    }
    return _postWithToken(action, body, authenticated ? _token : null);
  }

  Future<_PortalResponse> _postWithToken(
    String action,
    Map<String, String> body,
    String? token,
  ) async {
    // Answer a live block locally instead of sending. The portal's buckets
    // slide and a blocked request does NOT reset the count, it re-arms a FRESH
    // penalty, so every extra knock extends the user's own lockout. Deliberately
    // does NOT touch _rateLimitedUntil: only a real server 429 moves that clock.
    final blocked = rateLimitBackoff(action);
    if (blocked != null) {
      _warn('$action not sent: rate limited, ${blocked.inSeconds}s left');
      return _PortalResponse(429, const {}, 'rate_limited',
          retryAfter: blocked);
    }

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

      Duration? retryAfter;
      if (response.statusCode == 429) {
        retryAfter = _parseRetryAfter(response.headers['retry-after']);
        _rateLimitedUntil[action] = DateTime.now().add(retryAfter);
        _warn('$action rate limited, backing off ${retryAfter.inSeconds}s');
      }
      return _PortalResponse(response.statusCode, json, error,
          retryAfter: retryAfter);
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
    _linkedPubkeys = const [];
    _overview = null;
    _lastMeAt = null;
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
