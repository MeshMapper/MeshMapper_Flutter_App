import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/portal_account_service.dart';
import 'package:mesh_mapper/services/portal_token_store.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

void main() {
  late InMemoryTokenStore store;
  late List<http.Request> requests;

  setUp(() {
    store = InMemoryTokenStore();
    requests = [];
  });

  /// A MockClient that records every request and answers from [responder].
  MockClient recordingClient(
      http.Response Function(http.Request request) responder) {
    return MockClient((request) async {
      requests.add(request);
      return responder(request);
    });
  }

  PortalAccountService buildService(MockClient client) => PortalAccountService(
        client: client,
        store: store,
        // appLinks: null keeps the platform deep-link plugin out of unit tests;
        // callbacks are driven through handleAuthCallback() directly.
        launcher: (uri) async => true,
      );

  /// Seeds a pending PKCE pair as though beginSignIn() had run.
  Future<void> seedPending(String state, {Duration age = Duration.zero}) async {
    await store.writePendingPkce(PendingPkce(
      verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
      state: state,
      createdAt: DateTime.now().subtract(age),
    ));
  }

  String tokenBody() => jsonEncode({
        'ok': true,
        'token': 'f' * 64,
        'user': {'id': 7, 'username': 'sparkgap', 'display_name': 'Spark Gap'},
      });

  group('authorize URL', () {
    test('carries the locked PKCE and redirect parameters', () {
      final uri = PortalApi.authorizeUrl(
          codeChallenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
          state: 'st4te');
      expect(uri.host, 'portal.meshmapper.net');
      expect(uri.path, '/portal.php');
      expect(uri.queryParameters['app_authorize'], '1');
      expect(uri.queryParameters['code_challenge_method'], 'S256');
      expect(uri.queryParameters['redirect_uri'], 'meshmapper-auth://callback');
      expect(uri.queryParameters['state'], 'st4te');
      // The encoded form the portal byte-compares against.
      expect(uri.toString(),
          contains('redirect_uri=meshmapper-auth%3A%2F%2Fcallback'));
    });

    test('action() builds the machine-lane route', () {
      expect(PortalApi.action('nonce').toString(),
          'https://portal.meshmapper.net/portal_app_api.php?action=nonce');
    });
  });

  group('beginSignIn', () {
    test('persists a pending pair and opens the browser', () async {
      Uri? opened;
      final service = PortalAccountService(
        client: recordingClient((_) => http.Response('{}', 200)),
        store: store,
        launcher: (uri) async {
          opened = uri;
          return true;
        },
      );

      expect(await service.beginSignIn(), isTrue);

      final pending = await store.readPendingPkce();
      expect(pending, isNotNull);
      expect(pending!.verifier.length, 43);
      expect(opened, isNotNull);
      expect(opened!.queryParameters['state'], pending.state);
      expect(opened!.queryParameters['code_challenge']!.length, 43);
      expect(requests, isEmpty, reason: 'sign-in must not hit the API');
    });
  });

  group('handleAuthCallback', () {
    test('exchanges the code and persists the token', () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      var changed = 0;
      service.onAccountChanged = () => changed++;

      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=st4te'));

      expect(requests.length, 1);
      final request = requests.single;
      expect(request.url.queryParameters['action'], 'token');
      expect(request.headers['Content-Type'],
          contains('application/x-www-form-urlencoded'));
      expect(request.bodyFields['code'], 'a' * 64);
      expect(request.bodyFields['code_verifier'],
          'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk');
      // The token exchange is unauthenticated.
      expect(request.headers.containsKey('Authorization'), isFalse);

      expect(await store.readToken(), 'f' * 64);
      expect(await store.readPendingPkce(), isNull);
      expect(service.isSignedIn, isTrue);
      expect(service.account!.username, 'sparkgap');
      expect(service.account!.displayName, 'Spark Gap');
      expect(changed, 1);
    });

    test('ignores a state mismatch and makes zero HTTP calls', () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));

      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=wrong'));

      expect(requests, isEmpty);
      expect(service.isSignedIn, isFalse);
      expect(await store.readPendingPkce(), isNotNull,
          reason: 'a genuine callback may still arrive');
    });

    test('ignores a callback with no pending pair', () async {
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));

      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=st4te'));

      expect(requests, isEmpty);
      expect(service.isSignedIn, isFalse);
    });

    test('ignores an expired pending pair and reports it', () async {
      await seedPending('st4te', age: const Duration(minutes: 11));
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      bool? reported;
      String? errorCode;
      service.onSignInComplete = (success, code) {
        reported = success;
        errorCode = code;
      };

      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=st4te'));

      expect(requests, isEmpty);
      expect(await store.readPendingPkce(), isNull);
      // A real attempt was live and just died — the UI must stop spinning.
      expect(reported, isFalse);
      expect(errorCode, 'expired');
    });

    test('exchanges a given code only once', () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      final uri =
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=st4te');

      // app_links 6.x delivers the cold-start URI on BOTH getInitialLink()
      // and uriLinkStream; a second exchange would burn an already-used code.
      await service.handleAuthCallback(uri);
      await service.handleAuthCallback(uri);

      expect(requests.length, 1);
    });

    test('a concurrent duplicate delivery still exchanges only once', () async {
      // The init() race: the uriLinkStream listener runs unawaited while
      // getInitialLink() is still in flight, so both deliveries can be inside
      // handleAuthCallback at the same time. The gate parks them both on the
      // store read, which is where the guard used to leak.
      final gated = _GatedStore();
      await gated.writePendingPkce(PendingPkce(
        verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        state: 'st4te',
        createdAt: DateTime.now(),
      ));
      final service = PortalAccountService(
        client: recordingClient((_) => http.Response(tokenBody(), 200)),
        store: gated,
        launcher: (uri) async => true,
      );
      final uri =
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=st4te');

      final first = service.handleAuthCallback(uri);
      final second = service.handleAuthCallback(uri);
      gated.openGate();
      await Future.wait([first, second]);

      expect(requests.length, 1,
          reason: 'the portal burns a code on first use');
      expect(service.isSignedIn, isTrue);
      expect(gated.pendingReads, 1,
          reason: 'the duplicate must bounce before it reaches the store');
    });

    test('a state mismatch does not poison the code for the genuine callback',
        () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));

      // A stale or hostile callback carrying this code but the wrong state.
      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=wrong'));
      expect(requests, isEmpty);

      // The genuine callback arrives afterwards with the SAME code and must
      // still be exchangeable.
      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=st4te'));

      expect(requests.length, 1);
      expect(service.isSignedIn, isTrue);
    });

    test('access_denied clears the pending pair without an exchange', () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      bool? reported;
      String? code;
      service.onSignInComplete = (success, errorCode) {
        reported = success;
        code = errorCode;
      };

      await service.handleAuthCallback(Uri.parse(
          'meshmapper-auth://callback?error=access_denied&state=st4te'));

      expect(requests, isEmpty);
      expect(await store.readPendingPkce(), isNull);
      expect(reported, isFalse);
      expect(code, 'access_denied');
    });

    test('ignores a URI with a foreign scheme', () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));

      await service
          .handleAuthCallback(Uri.parse('meshmapper://custom-api?url=x&key=y'));
      await service.handleAuthCallback(Uri.parse(
          'meshmapper-auth://elsewhere?code=${'a' * 64}&state=st4te'));

      expect(requests, isEmpty);
    });

    test('a failed exchange leaves the user signed out', () async {
      await seedPending('st4te');
      final service = buildService(recordingClient(
          (_) => http.Response('{"error":"code_invalid"}', 400)));
      String? errorCode;
      service.onSignInComplete = (success, code) => errorCode = code;

      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=st4te'));

      expect(service.isSignedIn, isFalse);
      expect(await store.readToken(), isNull);
      expect(errorCode, 'code_invalid');
    });

    // A hostile or broken portal answering `"user": []` / `"user": "bob"` used
    // to throw a TypeError on the cast. Via the uriLinkStream listener that is
    // an unawaited future, so it became an unhandled zone error and the whole
    // attempt died silently with the code still claimed.
    for (final shape in <Object>[<Object>[], 'bob', 42]) {
      test('a non-object user (${shape.runtimeType}) is rejected, not thrown',
          () async {
        final localStore = InMemoryTokenStore();
        await localStore.writePendingPkce(PendingPkce(
          verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
          state: 'st4te',
          createdAt: DateTime.now(),
        ));
        final service = PortalAccountService(
          client: recordingClient((_) => http.Response(
              jsonEncode({'ok': true, 'token': 'f' * 64, 'user': shape}), 200)),
          store: localStore,
          launcher: (uri) async => true,
        );
        bool? reported;
        String? errorCode;
        service.onSignInComplete = (success, code) {
          reported = success;
          errorCode = code;
        };

        await service.handleAuthCallback(Uri.parse(
            'meshmapper-auth://callback?code=${'a' * 64}&state=st4te'));

        expect(service.isSignedIn, isFalse);
        expect(await localStore.readToken(), isNull);
        expect(reported, isFalse);
        expect(errorCode, 'bad_response');
      });
    }

    test('a throw inside the exchange cannot escape as a zone error', () async {
      final throwing = _ThrowingWriteStore();
      await throwing.writePendingPkce(PendingPkce(
        verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        state: 'st4te',
        createdAt: DateTime.now(),
      ));
      final service = PortalAccountService(
        client: recordingClient((_) => http.Response(tokenBody(), 200)),
        store: throwing,
        launcher: (uri) async => true,
      );
      String? errorCode;
      service.onSignInComplete = (success, code) => errorCode = code;

      // Must complete normally rather than propagating the keystore failure.
      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?code=${'a' * 64}&state=st4te'));

      expect(errorCode, 'bad_response');
    });
  });

  // A callback is unauthenticated: ANY app on the device can fire
  // meshmapper-auth://callback?error=... An error is therefore only believed
  // when it answers a sign-in we actually started.
  group('error callbacks are only honoured when they answer a live attempt',
      () {
    test('an error with no pending pair is ignored', () async {
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      var completions = 0;
      service.onSignInComplete = (_, __) => completions++;

      await service.handleAuthCallback(Uri.parse(
          'meshmapper-auth://callback?error=access_denied&state=st4te'));

      expect(completions, 0);
      expect(requests, isEmpty);
    });

    test('an error with a mismatched state leaves the pair intact', () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      var completions = 0;
      service.onSignInComplete = (_, __) => completions++;

      await service.handleAuthCallback(Uri.parse(
          'meshmapper-auth://callback?error=access_denied&state=wrong'));

      expect(completions, 0,
          reason: 'a foreign app must not fail a live sign-in');
      expect(await store.readPendingPkce(), isNotNull,
          reason: 'the genuine callback may still arrive');
    });

    test('a matching error is reported exactly once', () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      final reported = <String?>[];
      service.onSignInComplete = (success, code) => reported.add(code);
      final uri = Uri.parse(
          'meshmapper-auth://callback?error=access_denied&state=st4te');

      await service.handleAuthCallback(uri);
      await service.handleAuthCallback(uri);

      expect(reported, ['access_denied']);
      expect(await store.readPendingPkce(), isNull);
      expect(requests, isEmpty);
    });

    test('a hostile error value is sanitized before it is reported', () async {
      await seedPending('st4te');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      String? errorCode;
      service.onSignInComplete = (success, code) => errorCode = code;
      final hostile = Uri.encodeQueryComponent('<script>alert(1)</script>');

      await service.handleAuthCallback(
          Uri.parse('meshmapper-auth://callback?error=$hostile&state=st4te'));

      expect(errorCode, 'denied');
    });
  });

  group('logging never leaks a secret', () {
    test('token, code, verifier and state appear in no log line', () async {
      final logs = <String>[];
      final originalPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) logs.add(message);
      };
      DebugLogger.setEnabled(true);
      addTearDown(() {
        debugPrint = originalPrint;
        DebugLogger.setEnabled(false);
      });

      await seedPending('st4testate');
      final service =
          buildService(recordingClient((_) => http.Response(tokenBody(), 200)));
      await service.handleAuthCallback(Uri.parse(
          'meshmapper-auth://callback?code=${'a' * 64}&state=st4testate'));

      final joined = logs.join('\n');
      expect(joined, isNot(contains('f' * 64)), reason: 'token leaked');
      expect(joined, isNot(contains('a' * 64)), reason: 'code leaked');
      expect(joined,
          isNot(contains('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk')),
          reason: 'verifier leaked');
      expect(joined, isNot(contains('st4testate')), reason: 'state leaked');
      expect(joined, contains('[ACCOUNT]'),
          reason: 'the flow should log something');
    });
  });
}

/// A store whose `readPendingPkce` parks until [openGate] is called, so a test
/// can hold two `handleAuthCallback` calls inside the duplicate guard at once.
class _GatedStore extends InMemoryTokenStore {
  final Completer<void> _gate = Completer<void>();

  /// How many times the callback flow got as far as reading the pending pair.
  int pendingReads = 0;

  void openGate() => _gate.complete();

  @override
  Future<PendingPkce?> readPendingPkce() async {
    pendingReads++;
    await _gate.future;
    return super.readPendingPkce();
  }
}

/// A store whose token write blows up, the way a wedged keystore does. Stands
/// in for any throw raised inside the exchange after validation has passed.
class _ThrowingWriteStore extends InMemoryTokenStore {
  @override
  Future<void> writeToken(String value) async =>
      throw StateError('keystore unavailable');
}
