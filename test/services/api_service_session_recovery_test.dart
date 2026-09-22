import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// A live connection can replace an expired geo-auth session without dropping
/// the companion. The provider owns the actual auth payload because it owns
/// the live radio metadata; ApiService owns recognizing the one recoverable
/// server verdict and serializing callers behind that refresh.
void main() {
  ({ApiService api, List<String> events, int Function() authCount}) build() {
    final events = <String>[];
    var authCount = 0;
    final api = ApiService(
      client: MockClient((request) async {
        final body = json.decode(request.body) as Map<String, dynamic>;
        if (request.url.path.endsWith('/auth')) {
          authCount++;
          return http.Response(
            json.encode({
              'success': true,
              'session_id': authCount == 1 ? 'old-session' : 'new-session',
              'tx_allowed': true,
              'rx_allowed': true,
              'expires_at':
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
              'channels': ['public', 'refreshed'],
              'scopes': ['refreshed'],
              'smart_ping': true,
              'smart_ping_days': 21,
            }),
            200,
          );
        }

        if (body['session_id'] == 'old-session') {
          return http.Response(
            json.encode({
              'success': false,
              'reason': 'session_expired',
              'message': 'expired for test',
            }),
            401,
          );
        }
        return http.Response(
          json.encode({
            'success': true,
            'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
          }),
          200,
        );
      }),
    );
    return (api: api, events: events, authCount: () => authCount);
  }

  Future<void> connect(ApiService api) => api.requestAuth(
        reason: 'connect',
        publicKey: 'AB',
        lat: 45.0,
        lon: -75.0,
      );

  test('an expired preflight refreshes the live session before allowing send',
      () async {
    final built = build();
    await connect(built.api);
    built.api.onSessionIdChanged = (oldId, newId) async {
      built.events.add('drop:$oldId:$newId');
    };
    built.api.onSessionExpiredRecovery = () async {
      built.events.add('recover');
      await connect(built.api);
      built.events.add('auth-complete');
      return SessionRecoveryResult.recovered;
    };

    final check = await built.api.checkSessionValid();

    expect(check.isValid, isTrue);
    expect(built.api.sessionId, 'new-session');
    expect(built.api.channels, ['public', 'refreshed']);
    expect(built.api.scopes, ['refreshed']);
    expect(built.api.enforceSmartPing, isTrue);
    expect(built.api.apiSmartPingDays, 21);
    expect(built.events,
        ['recover', 'drop:old-session:new-session', 'auth-complete']);
  });

  test('concurrent expired preflights share one re-authentication', () async {
    final built = build();
    await connect(built.api);
    final gate = Completer<void>();
    built.api.onSessionExpiredRecovery = () async {
      built.events.add('recover');
      await gate.future;
      await connect(built.api);
      return SessionRecoveryResult.recovered;
    };

    final first = built.api.checkSessionValid();
    final second = built.api.checkSessionValid();
    await Future<void>.delayed(Duration.zero);
    gate.complete();
    final results = await Future.wait([first, second]);

    expect(results.every((result) => result.isValid), isTrue);
    expect(built.events, ['recover']);
    expect(built.authCount(), 2,
        reason: 'one initial auth plus one shared replacement auth');
  });

  test('an expired upload holds its batch after the session refresh', () async {
    final built = build();
    await connect(built.api);
    built.api.onSessionExpiredRecovery = () async {
      await connect(built.api);
      return SessionRecoveryResult.recovered;
    };

    final result = await built.api.uploadBatch([
      {'type': 'RX', 'lat': 45.0, 'lon': -75.0}
    ]);

    expect(result, UploadResult.held,
        reason: 'the queue retries the unchanged batch under the new session');
    expect(built.api.sessionId, 'new-session');
  });

  test('a different session error stays fatal instead of refreshing', () async {
    var recoveryCalls = 0;
    var sessionErrors = 0;
    final api = ApiService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          return http.Response(
            json.encode({
              'success': true,
              'session_id': 'live-session',
              'tx_allowed': true,
              'rx_allowed': true,
              'expires_at': DateTime.now().millisecondsSinceEpoch ~/ 1000 +
                  3600,
            }),
            200,
          );
        }
        return http.Response(
          json.encode({
            'success': false,
            'reason': 'session_invalid',
            'message': 'invalid for test',
          }),
          401,
        );
      }),
    );
    await connect(api);
    api.onSessionExpiredRecovery = () async {
      recoveryCalls++;
      return SessionRecoveryResult.recovered;
    };
    api.onSessionError = (reason, message, {subReason}) async {
      sessionErrors++;
    };

    final check = await api.checkSessionValid();

    expect(check.isValid, isFalse);
    expect(recoveryCalls, 0);
    expect(sessionErrors, 1);
    expect(api.sessionId, isNull);
  });

  test('an invalidated replacement auth leaves the live session untouched',
      () async {
    final built = build();
    await connect(built.api);

    final replacement = await built.api.requestAuth(
      reason: 'connect',
      publicKey: 'AB',
      lat: 45.0,
      lon: -75.0,
      shouldStoreSession: () => false,
    );

    expect(replacement?['success'], isTrue);
    expect(built.api.sessionId, 'old-session',
        reason: 'a delayed recovery must not replace a connection it no longer owns');
  });

  test('invalidation during stale-tag cleanup prevents the session swap',
      () async {
    final built = build();
    await connect(built.api);
    var ownsRecovery = true;
    built.api.onSessionIdChanged = (oldId, newId) async {
      ownsRecovery = false;
    };

    await built.api.requestAuth(
      reason: 'connect',
      publicKey: 'AB',
      lat: 45.0,
      lon: -75.0,
      shouldStoreSession: () => ownsRecovery,
    );

    expect(built.api.sessionId, 'old-session',
        reason: 'cleanup can yield to disconnect, so ownership is checked again');
  });

  test('a superseded preflight stays invalid without clearing a newer session',
      () async {
    final built = build();
    await connect(built.api);
    var sessionErrors = 0;
    built.api.onSessionExpiredRecovery = () async =>
        SessionRecoveryResult.superseded;
    built.api.onSessionError = (reason, message, {subReason}) async {
      sessionErrors++;
    };

    final check = await built.api.checkSessionValid();

    expect(check.isValid, isFalse);
    expect(check.reason, 'session_expired');
    expect(built.api.sessionId, 'old-session');
    expect(sessionErrors, 0,
        reason: 'a stale request must not disconnect the replacement owner');
  });

  test('a superseded upload remains held without fatal cleanup', () async {
    final built = build();
    await connect(built.api);
    var sessionErrors = 0;
    built.api.onSessionExpiredRecovery = () async =>
        SessionRecoveryResult.superseded;
    built.api.onSessionError = (reason, message, {subReason}) async {
      sessionErrors++;
    };

    final result = await built.api.uploadBatch([
      {'type': 'RX', 'lat': 45.0, 'lon': -75.0}
    ]);

    expect(result, UploadResult.held);
    expect(built.api.sessionId, 'old-session');
    expect(sessionErrors, 0);
  });

  test('a failed recovery stays fatal', () async {
    final built = build();
    await connect(built.api);
    var sessionErrors = 0;
    built.api.onSessionExpiredRecovery = () async =>
        SessionRecoveryResult.failed;
    built.api.onSessionError = (reason, message, {subReason}) async {
      sessionErrors++;
    };

    final check = await built.api.checkSessionValid();

    expect(check.isValid, isFalse);
    expect(built.api.sessionId, isNull);
    expect(sessionErrors, 1);
  });

  test('an invalidated auth failure remains nonfatal', () async {
    final built = build();
    await connect(built.api);
    final authGate = Completer<void>();
    var invalidated = false;
    var sessionErrors = 0;
    built.api.onSessionExpiredRecovery = () async {
      await authGate.future;
      return invalidated
          ? SessionRecoveryResult.superseded
          : SessionRecoveryResult.failed;
    };
    built.api.onSessionError = (reason, message, {subReason}) async {
      sessionErrors++;
    };

    final check = built.api.checkSessionValid();
    await Future<void>.delayed(Duration.zero);
    invalidated = true;
    authGate.complete();

    expect((await check).isValid, isFalse);
    expect(built.api.sessionId, 'old-session');
    expect(sessionErrors, 0);
  });

  test('an invalidated configuration failure remains nonfatal', () async {
    final built = build();
    await connect(built.api);
    final configGate = Completer<void>();
    var invalidated = false;
    var sessionErrors = 0;
    built.api.onSessionExpiredRecovery = () async {
      await configGate.future;
      return invalidated
          ? SessionRecoveryResult.superseded
          : SessionRecoveryResult.failed;
    };
    built.api.onSessionError = (reason, message, {subReason}) async {
      sessionErrors++;
    };

    final check = built.api.checkSessionValid();
    await Future<void>.delayed(Duration.zero);
    invalidated = true;
    configGate.complete();

    expect((await check).isValid, isFalse);
    expect(built.api.sessionId, 'old-session');
    expect(sessionErrors, 0);
  });
}
