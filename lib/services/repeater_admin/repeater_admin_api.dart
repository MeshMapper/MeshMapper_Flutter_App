import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../utils/debug_logger_io.dart';
import '../../utils/public_key.dart';
import '../api_service.dart';
import 'repeater_admin_models.dart';

enum RepeaterAdminFailureKind {
  none,
  noSession,
  unsupported,
  notAdmin,
  noClaim,
  unknownRepeater,
  tooManyAdmins,
  rateLimited,
  sessionExpired,
  invalid,
  network,
}

class RepeaterAdminResult {
  final bool ok;
  final RepeaterAdminFailureKind failure;
  final String? message;
  final Duration? retryAfter;
  final List<String> administrators;
  final List<RepeaterClaim> claims;
  final int? resolved;
  final int? unresolved;
  final int? claimedAt;
  final int? updatedAt;

  const RepeaterAdminResult({
    required this.ok,
    this.failure = RepeaterAdminFailureKind.none,
    this.message,
    this.retryAfter,
    this.administrators = const [],
    this.claims = const [],
    this.resolved,
    this.unresolved,
    this.claimedAt,
    this.updatedAt,
  });

  const RepeaterAdminResult.failed(this.failure,
      {this.message, this.retryAfter})
      : ok = false,
        administrators = const [],
        claims = const [],
        resolved = null,
        unresolved = null,
        claimedAt = null,
        updatedAt = null;

  /// A sentence for the sheet.
  String get userMessage {
    switch (failure) {
      case RepeaterAdminFailureKind.none:
        return '';
      case RepeaterAdminFailureKind.noSession:
        return 'Claiming needs an online session. Turn off Offline Mode and reconnect.';
      case RepeaterAdminFailureKind.unsupported:
        return 'This region does not support claiming yet.';
      case RepeaterAdminFailureKind.notAdmin:
        return 'The server did not accept the admin proof.';
      case RepeaterAdminFailureKind.noClaim:
        return 'Claim this repeater before uploading its neighbours.';
      case RepeaterAdminFailureKind.unknownRepeater:
        return 'MeshMapper does not know this repeater in your region.';
      case RepeaterAdminFailureKind.tooManyAdmins:
        return 'This repeater already has the maximum number of administrators.';
      case RepeaterAdminFailureKind.rateLimited:
        return 'Too many requests. Try again in ${_waitLabel(retryAfter)}.';
      case RepeaterAdminFailureKind.sessionExpired:
        return 'Your wardriving session has expired. Reconnect and try again.';
      case RepeaterAdminFailureKind.invalid:
        return 'The server rejected the request.';
      case RepeaterAdminFailureKind.network:
        return 'Could not reach MeshMapper. Check your connection and try again.';
    }
  }

  static String _waitLabel(Duration? wait) {
    final w = wait ?? ApiService.defaultWardriveRetryAfter;
    if (w.inSeconds < 60) return '${w.inSeconds} seconds';
    final minutes = (w.inSeconds / 60).ceil();
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }
}

/// POST /wardrive-api.php/repeater under the live wardrive session.
///
/// The body never carries a top-level `data`, `public_key`, `heartbeat`,
/// `lat`, `lng` or `lon`: an old server's router keys on those, and the
/// `invalid_request` it answers instead is how the app learns the region has
/// no `/repeater` leg yet. [forbiddenTopLevelKeys] is asserted on every post.
class RepeaterAdminApi {
  static const String endpoint =
      '${ApiService.baseUrl}/wardrive-api.php/repeater';
  static const Set<String> forbiddenTopLevelKeys = {
    'data',
    'public_key',
    'heartbeat',
    'lat',
    'lng',
    'lon',
  };
  static const Duration _timeout = Duration(seconds: 30);

  final http.Client _client;
  final String? Function() _sessionId;
  final String Function() _appVersion;

  RepeaterAdminApi({
    required http.Client client,
    required String? Function() sessionId,
    required String Function() appVersion,
  })  : _client = client,
        _sessionId = sessionId,
        _appVersion = appVersion;

  Future<RepeaterAdminResult> claim(
      String repeaterHex, Map<String, dynamic> proof) {
    final key = normalizePublicKey(repeaterHex);
    if (key == null) {
      return Future.value(
          const RepeaterAdminResult.failed(RepeaterAdminFailureKind.invalid));
    }
    return _post('claim', {'repeater': key, 'proof': proof});
  }

  Future<RepeaterAdminResult> unclaim(String repeaterHex) {
    final key = normalizePublicKey(repeaterHex);
    if (key == null) {
      return Future.value(
          const RepeaterAdminResult.failed(RepeaterAdminFailureKind.invalid));
    }
    return _post('unclaim', {'repeater': key});
  }

  Future<RepeaterAdminResult> mine() => _post('mine', const {});

  Future<RepeaterAdminResult> neighbours(
      String repeaterHex, Map<String, dynamic> table) {
    final key = normalizePublicKey(repeaterHex);
    if (key == null) {
      return Future.value(
          const RepeaterAdminResult.failed(RepeaterAdminFailureKind.invalid));
    }
    return _post('neighbours', {'repeater': key, 'neighbours': table});
  }

  Future<RepeaterAdminResult> _post(
      String action, Map<String, dynamic> fields) async {
    final sessionId = _sessionId();
    if (sessionId == null) {
      debugLog('[RADMIN] $action skipped: no wardrive session');
      return const RepeaterAdminResult.failed(
          RepeaterAdminFailureKind.noSession);
    }
    final body = <String, dynamic>{
      'key': ApiService.apiKey,
      'session_id': sessionId,
      'action': action,
      'app_ver': _appVersion(),
      ...fields,
    };
    assert(body.keys.every((k) => !forbiddenTopLevelKeys.contains(k)),
        'A /repeater body must never carry ${forbiddenTopLevelKeys.join(', ')}');

    final stopwatch = Stopwatch()..start();
    http.Response response;
    try {
      response = await _client
          .post(Uri.parse(endpoint),
              headers: {'Content-Type': 'application/json'},
              body: json.encode(body))
          .timeout(_timeout);
    } catch (e) {
      debugError(
          '[RADMIN] POST /repeater $action failed to reach the server: $e');
      return const RepeaterAdminResult.failed(RepeaterAdminFailureKind.network);
    }
    stopwatch.stop();

    Map<String, dynamic> data;
    try {
      final decoded = json.decode(response.body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('not an object');
      }
      data = decoded;
    } on FormatException {
      debugError('[RADMIN] POST /repeater $action: non-JSON body '
          '(HTTP ${response.statusCode})');
      return const RepeaterAdminResult.failed(RepeaterAdminFailureKind.invalid);
    }

    final reason = data['reason'] as String?;
    final message = data['message'] as String?;
    debugLog('[RADMIN] POST /repeater $action -> HTTP ${response.statusCode} '
        '${data['success'] == true ? 'ok' : 'reason=$reason'} '
        '(${stopwatch.elapsedMilliseconds}ms)');

    if (response.statusCode == 429 || reason == 'rate_limited') {
      return RepeaterAdminResult.failed(RepeaterAdminFailureKind.rateLimited,
          message: message,
          retryAfter:
              ApiService.parseRetryAfter(response.headers['retry-after']));
    }
    if (data['success'] == true) {
      return RepeaterAdminResult(
        ok: true,
        administrators: _strings(data['administrators']),
        claims: _claims(data['claims']),
        resolved: data['resolved'] as int?,
        unresolved: data['unresolved'] as int?,
        claimedAt: data['claimed_at'] as int?,
        updatedAt: data['updated_at'] as int?,
      );
    }
    return RepeaterAdminResult.failed(_kindFor(response.statusCode, reason),
        message: message);
  }

  static RepeaterAdminFailureKind _kindFor(int status, String? reason) {
    switch (reason) {
      case 'invalid_request': // an old server's router: no /repeater leg
      case 'unsupported':
        return RepeaterAdminFailureKind.unsupported;
      case 'not_admin':
        return RepeaterAdminFailureKind.notAdmin;
      case 'no_claim':
        return RepeaterAdminFailureKind.noClaim;
      case 'unknown_repeater':
        return RepeaterAdminFailureKind.unknownRepeater;
      case 'too_many_admins':
        return RepeaterAdminFailureKind.tooManyAdmins;
      case 'session_expired':
      case 'session_invalid':
      case 'session_revoked':
      case 'bad_session':
      case 'sessionKeyMismatch':
        return RepeaterAdminFailureKind.sessionExpired;
      case 'invalid':
        return RepeaterAdminFailureKind.invalid;
    }
    if (status == 401) return RepeaterAdminFailureKind.sessionExpired;
    if (status == 404) return RepeaterAdminFailureKind.unsupported;
    return RepeaterAdminFailureKind.invalid;
  }

  static List<String> _strings(Object? raw) =>
      raw is List ? raw.whereType<String>().toList() : const [];

  static List<RepeaterClaim> _claims(Object? raw) {
    if (raw is! List) return const [];
    final out = <RepeaterClaim>[];
    for (final row in raw) {
      if (row is Map<String, dynamic>) {
        final c = RepeaterClaim.tryFromJson(row);
        if (c != null) out.add(c);
      }
    }
    return out;
  }
}
