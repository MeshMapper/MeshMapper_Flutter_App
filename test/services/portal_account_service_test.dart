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

    test('a concurrent duplicate error is reported only once', () async {
      // Same init() race as the code path: getInitialLink() and the
      // uriLinkStream listener can both be inside handleAuthCallback at once.
      // Sequential dedupe falls out of the pair being burned, but two
      // deliveries parked on the store read would BOTH fire onSignInComplete.
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
      final reported = <String?>[];
      service.onSignInComplete = (success, code) => reported.add(code);
      final uri = Uri.parse(
          'meshmapper-auth://callback?error=access_denied&state=st4te');

      final first = service.handleAuthCallback(uri);
      final second = service.handleAuthCallback(uri);
      gated.openGate();
      await Future.wait([first, second]);

      expect(reported, ['access_denied']);
      expect(gated.pendingReads, 1,
          reason: 'the duplicate must bounce before it reaches the store');
      expect(requests, isEmpty);
    });

    test('a wedged keystore still lets the decline reach the UI', () async {
      // handleAuthCallback runs unawaited off the uriLinkStream, so a throwing
      // deletePendingPkce would escape as a zone error and leave the UI
      // spinning on a sign-in that has already been refused.
      final wedged = _ThrowingDeletePendingStore();
      await wedged.writePendingPkce(PendingPkce(
        verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        state: 'st4te',
        createdAt: DateTime.now(),
      ));
      final service = PortalAccountService(
        client: recordingClient((_) => http.Response(tokenBody(), 200)),
        store: wedged,
        launcher: (uri) async => true,
      );
      String? errorCode;
      service.onSignInComplete = (success, code) => errorCode = code;

      await service.handleAuthCallback(Uri.parse(
          'meshmapper-auth://callback?error=access_denied&state=st4te'));

      expect(errorCode, 'access_denied');
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

  group('authenticated calls', () {
    Future<PortalAccountService> signedIn(MockClient client) async {
      store.token = 'f' * 64;
      final service = buildService(client);
      await service.init();
      return service;
    }

    /// Answers per `?action=`, so one test can seed the cache with `me` and
    /// then exercise `link`/`unlink` against a cache that is not empty.
    MockClient routedClient(Map<String, http.Response> byAction) =>
        recordingClient((request) =>
            byAction[request.url.queryParameters['action']] ??
            http.Response('{"error":"unexpected_action"}', 500));

    String meBody(List<Map<String, Object>> pubkeys) => jsonEncode({
          'ok': true,
          'user': {'id': 7, 'username': 'sparkgap'},
          'pubkeys': pubkeys,
        });

    test('send both auth headers and a form-encoded body', () async {
      final service = await signedIn(recordingClient(
          (_) => http.Response('{"nonce":"${'b' * 64}"}', 200)));

      // Mixed case in, UPPER out.
      final lowerPubkey = 'abc123${'d' * 58}';
      await service.requestNonce(lowerPubkey);

      final request = requests.single;
      expect(request.headers['Authorization'], 'Bearer ${'f' * 64}');
      expect(request.headers['X-MM-App-Token'], 'f' * 64);
      expect(request.headers['Content-Type'],
          contains('application/x-www-form-urlencoded'));
      expect(request.url.queryParameters['action'], 'nonce');
      // pubkey is normalised to UPPER hex.
      expect(request.bodyFields['pubkey'], lowerPubkey.toUpperCase());
      // Form, never JSON.
      expect(request.body, isNot(startsWith('{')));
    });

    test('nonce is accepted without an ok flag', () async {
      final service = await signedIn(recordingClient((_) =>
          http.Response('{"nonce":"${'b' * 64}","expires_at":123}', 200)));
      expect(await service.requestNonce('A' * 64), 'b' * 64);
    });

    test('a nonce that is not 64 hex is rejected', () async {
      final service = await signedIn(
          recordingClient((_) => http.Response('{"nonce":"short"}', 200)));
      expect(await service.requestNonce('A' * 64), isNull);
    });

    test('link success maps to LinkSuccess and carries the nonce', () async {
      final service = await signedIn(recordingClient(
          (_) => http.Response('{"ok":true,"pubkey":"${'A' * 64}"}', 200)));

      final result = await service.linkDevice(
        pubkey: 'a' * 64,
        nonce: 'b' * 64,
        signature: 'c' * 128,
        label: 'Ikoka Stick',
      );

      expect(result, isA<LinkSuccess>());
      expect((result as LinkSuccess).already, isFalse);
      final body = requests.single.bodyFields;
      expect(body['pubkey'], 'A' * 64);
      expect(body['nonce'], 'b' * 64);
      expect(body['signature'], 'c' * 128);
      expect(body['label'], 'Ikoka Stick');
    });

    test('an idempotent relink reports already=true', () async {
      final service = await signedIn(recordingClient((_) => http.Response(
          '{"ok":true,"already":true,"pubkey":"${'A' * 64}"}', 200)));
      final result = await service.linkDevice(
          pubkey: 'A' * 64, nonce: 'b' * 64, signature: 'c' * 128);
      expect((result as LinkSuccess).already, isTrue);
    });

    test('already_linked maps to LinkAlreadyLinkedOtherAccount', () async {
      final service = await signedIn(recordingClient(
          (_) => http.Response('{"error":"already_linked"}', 409)));
      expect(
        await service.linkDevice(
            pubkey: 'A' * 64, nonce: 'b' * 64, signature: 'c' * 128),
        isA<LinkAlreadyLinkedOtherAccount>(),
      );
    });

    test('adoption_required carries the device count', () async {
      final service = await signedIn(recordingClient((_) =>
          http.Response('{"error":"adoption_required","devices":4}', 409)));
      final result = await service.linkDevice(
          pubkey: 'A' * 64, nonce: 'b' * 64, signature: 'c' * 128);
      expect(result, isA<LinkAdoptionRequired>());
      expect((result as LinkAdoptionRequired).devices, 4);
    });

    test('bad_signature maps to LinkServerError with its code', () async {
      final service = await signedIn(recordingClient(
          (_) => http.Response('{"error":"bad_signature"}', 400)));
      final result = await service.linkDevice(
          pubkey: 'A' * 64, nonce: 'b' * 64, signature: 'c' * 128);
      expect((result as LinkServerError).code, 'bad_signature');
      expect(result.statusCode, 400);
    });

    test('401 token_invalid signs the user out and deletes the token',
        () async {
      final service = await signedIn(recordingClient(
          (_) => http.Response('{"error":"token_invalid"}', 401)));
      var reason = '';
      service.onSignedOut = (value) => reason = value;

      final result = await service.linkDevice(
          pubkey: 'A' * 64, nonce: 'b' * 64, signature: 'c' * 128);

      expect(result, isA<LinkUnauthorized>());
      expect(service.isSignedIn, isFalse);
      expect(await store.readToken(), isNull);
      expect(reason, 'token_invalid');
    });

    test('a bare 401 is a network error and keeps the session', () async {
      // Captive portals and WAFs emit body-less 401s. Treating those as
      // "signed out" would log users out on hotel wifi.
      final service =
          await signedIn(recordingClient((_) => http.Response('', 401)));
      final result = await service.linkDevice(
          pubkey: 'A' * 64, nonce: 'b' * 64, signature: 'c' * 128);

      expect(result, isA<LinkNetworkError>());
      expect(service.isSignedIn, isTrue);
      expect(await store.readToken(), 'f' * 64);
    });

    test('me populates the linked-device list', () async {
      final service = await signedIn(recordingClient((_) => http.Response(
          jsonEncode({
            'ok': true,
            'user': {'id': 7, 'username': 'sparkgap'},
            'pubkeys': [
              {
                'pubkey': ('e' * 64),
                'label': 'Stick',
                'name': 'WX7RAW',
                'points': 12,
              }
            ],
          }),
          200)));

      expect(await service.refreshMe(), isTrue);
      expect(service.linkedPubkeys.length, 1);
      expect(service.linkedPubkeys.single.pubkey, ('e' * 64).toUpperCase());
      expect(service.linkedPubkeys.single.points, 12);
      expect(service.account!.displayName, 'sparkgap');
    });

    test('me is throttled to once an hour unless forced', () async {
      final service = await signedIn(recordingClient((_) => http.Response(
          '{"ok":true,"user":{"id":7,"username":"a"},"pubkeys":[]}', 200)));

      expect(await service.refreshMe(), isTrue);
      expect(await service.refreshMe(), isFalse);
      expect(requests.length, 1);
      expect(await service.refreshMe(force: true), isTrue);
      expect(requests.length, 2);
    });

    test('a non-object user in me is rejected, not thrown', () async {
      // Same hostile shape the token exchange already defends against; me is
      // awaited by the provider, so a TypeError here would surface as a
      // failed reconnect rather than a skipped refresh.
      final service = await signedIn(recordingClient(
          (_) => http.Response('{"ok":true,"user":[],"pubkeys":[]}', 200)));
      expect(await service.refreshMe(), isTrue);
      expect(service.account, isNull);
    });

    test('a successful link lands in the cache exactly once', () async {
      final service = await signedIn(routedClient({
        'link': http.Response(
            '{"ok":true,"pubkey":"${'A' * 64}","name":"WX7RAW","points":5}',
            200),
      }));
      var changed = 0;
      service.onAccountChanged = () => changed++;

      expect(
        await service.linkDevice(
            pubkey: 'a' * 64,
            nonce: 'b' * 64,
            signature: 'c' * 128,
            label: 'Ikoka Stick'),
        isA<LinkSuccess>(),
      );

      final entry = service.linkedPubkeys.single;
      expect(entry.pubkey, 'A' * 64);
      expect(entry.label, 'Ikoka Stick');
      expect(entry.name, 'WX7RAW');
      expect(entry.points, 5);
      expect(changed, 1);

      // A relink of the SAME radio must not duplicate the entry, and must not
      // re-notify: the UI would rebuild the device list for nothing.
      expect(
        await service.linkDevice(
            pubkey: 'a' * 64, nonce: 'b' * 64, signature: 'c' * 128),
        isA<LinkSuccess>(),
      );
      expect(service.linkedPubkeys.length, 1);
      expect(changed, 1, reason: 'nothing was added the second time');
    });

    test('a link with no label caches an empty label', () async {
      final service = await signedIn(routedClient({
        'link': http.Response('{"ok":true,"pubkey":"${'A' * 64}"}', 200),
      }));
      await service.linkDevice(
          pubkey: 'A' * 64, nonce: 'b' * 64, signature: 'c' * 128);
      expect(service.linkedPubkeys.single.label, '');
      expect(service.linkedPubkeys.single.name, '');
      expect(service.linkedPubkeys.single.points, 0);
    });

    test('unlink removes only the named pubkey and keeps the rest', () async {
      final service = await signedIn(routedClient({
        'me': http.Response(
            meBody([
              {
                'pubkey': 'a' * 64,
                'label': 'Stick',
                'name': 'WX7RAW',
                'points': 12
              },
              {
                'pubkey': 'e' * 64,
                'label': 'Nano',
                'name': 'WX7NAN',
                'points': 3
              },
            ]),
            200),
        'unlink': http.Response('{"ok":true}', 200),
      }));

      // Seed a NON-EMPTY cache first — unlinking out of an empty list passes
      // even when the removal never happens.
      expect(await service.refreshMe(), isTrue);
      expect(service.linkedPubkeys.length, 2);

      var changed = 0;
      service.onAccountChanged = () => changed++;

      expect(await service.unlinkDevice('a' * 64), isTrue);

      expect(service.linkedPubkeys.map((p) => p.pubkey).toList(),
          [('e' * 64).toUpperCase()]);
      expect(changed, 1);
    });

    test('a refused unlink leaves the cache alone', () async {
      final service = await signedIn(routedClient({
        'me': http.Response(
            meBody([
              {'pubkey': 'a' * 64, 'label': '', 'name': '', 'points': 0}
            ]),
            200),
        'unlink': http.Response('{"error":"not_found"}', 404),
      }));
      expect(await service.refreshMe(), isTrue);
      var changed = 0;
      service.onAccountChanged = () => changed++;

      expect(await service.unlinkDevice('a' * 64), isFalse);
      expect(service.linkedPubkeys.length, 1);
      expect(changed, 0);
    });

    test('a link keeps the pubkeys restored from the cache', () async {
      final service = await signedIn(routedClient({
        'link': http.Response('{"ok":true,"pubkey":"${'C' * 64}"}', 200),
      }));

      // Exactly what the provider does on startup: replay the Hive cache into
      // the service before anything can mutate it.
      service.hydrateLinkedPubkeys([('a' * 64), ('b' * 64).toUpperCase()]);
      expect(service.linkedPubkeys.length, 2);

      expect(
        await service.linkDevice(
            pubkey: 'c' * 64, nonce: 'd' * 64, signature: 'e' * 128),
        isA<LinkSuccess>(),
      );

      // The provider mirrors this list back wholesale, so a dropped A/B here
      // is a wiped cache on disk.
      expect(
        service.linkedPubkeys.map((p) => p.pubkey).toList(),
        [('A' * 64), ('B' * 64), ('C' * 64)],
      );
    });

    test('an unlink removes only its own pubkey from a restored cache',
        () async {
      final service = await signedIn(routedClient({
        'unlink': http.Response('{"ok":true}', 200),
      }));

      service.hydrateLinkedPubkeys([('a' * 64), ('b' * 64)]);

      expect(await service.unlinkDevice('a' * 64), isTrue);

      expect(service.linkedPubkeys.map((p) => p.pubkey).toList(), [('B' * 64)]);
    });

    test('hydrating the cache does not notify', () async {
      final service = await signedIn(routedClient(const {}));
      var changed = 0;
      service.onAccountChanged = () => changed++;

      service.hydrateLinkedPubkeys([('a' * 64)]);

      expect(service.linkedPubkeys.length, 1);
      expect(changed, 0, reason: 'a load is not a change');
      expect(requests, isEmpty);
    });

    test('a signed-out link is refused without any HTTP call', () async {
      final service = buildService(
          recordingClient((_) => http.Response('{"ok":true}', 200)));
      await service.init();
      expect(service.isSignedIn, isFalse);

      final result = await service.linkDevice(
          pubkey: 'a' * 64, nonce: 'b' * 64, signature: 'c' * 128);

      expect(result, isA<LinkNetworkError>());
      expect((result as LinkNetworkError).detail, 'no_token');
      expect(requests, isEmpty,
          reason: 'a header-less POST can only ever be refused');
    });

    test('a signed-out nonce request makes no HTTP call', () async {
      final service = buildService(recordingClient(
          (_) => http.Response('{"nonce":"${'b' * 64}"}', 200)));
      await service.init();

      expect(await service.requestNonce('A' * 64), isNull);
      expect(requests, isEmpty);
    });

    test('logout clears locally even when the revoke POST fails', () async {
      final service =
          await signedIn(recordingClient((_) => http.Response('boom', 500)));

      await service.logout();

      expect(service.isSignedIn, isFalse);
      expect(service.account, isNull);
      expect(await store.readToken(), isNull);
      // One attempt plus exactly one retry.
      expect(requests.length, 2);
      expect(requests.every((r) => r.url.queryParameters['action'] == 'logout'),
          isTrue);
    });

    test('logout still sends the token it just deleted', () async {
      final service = await signedIn(
          recordingClient((_) => http.Response('{"ok":true}', 200)));
      await service.logout();
      expect(requests.single.headers['X-MM-App-Token'], 'f' * 64);
    });

    /// The backoff is what is LEFT of the block, so it lands a hair under the
    /// granted duration. Anything that ran a real clock is close enough.
    void expectBackoff(Duration? actual, Duration granted) {
      expect(actual, isNotNull);
      expect(actual!, lessThanOrEqualTo(granted));
      expect(actual, greaterThan(granted - const Duration(seconds: 5)));
    }

    // Every 429 the portal sends is terminal and carries Retry-After. Its
    // buckets slide with a rolling penalty, so a blocked call that gets
    // retried re-arms a fresh block instead of letting the old one expire.
    http.Response rateLimited({String? retryAfter}) => http.Response(
          '{"error":"rate_limited"}',
          429,
          headers: {if (retryAfter != null) 'retry-after': retryAfter},
        );

    test('a 429 on me blocks the next refresh even when it is forced',
        () async {
      final service =
          await signedIn(recordingClient((_) => rateLimited(retryAfter: '600')));

      expect(await service.refreshMe(), isFalse);
      expect(requests.length, 1);

      // force skips the local hourly throttle, never a server backoff.
      expect(await service.refreshMe(force: true), isFalse);
      expect(requests.length, 1,
          reason: 'a blocked route must not be hit again');

      expectBackoff(
          service.rateLimitBackoff('me'), const Duration(seconds: 600));
    });

    test('a 429 is not a sign-out', () async {
      final service =
          await signedIn(recordingClient((_) => rateLimited(retryAfter: '600')));

      await service.refreshMe();

      expect(service.isSignedIn, isTrue);
      expect(await store.readToken(), 'f' * 64);
    });

    test('a 429 with no Retry-After still blocks for the default', () async {
      final service = await signedIn(recordingClient((_) => rateLimited()));

      await service.refreshMe();

      expectBackoff(service.rateLimitBackoff('me'), PortalApi.defaultRetryAfter);
    });

    test('an unparseable Retry-After falls back to the default', () async {
      final service = await signedIn(recordingClient(
          (_) => rateLimited(retryAfter: 'Sun, 23 Aug 2026 21:00:00 GMT')));

      await service.refreshMe();

      expectBackoff(service.rateLimitBackoff('me'), PortalApi.defaultRetryAfter);
    });

    test('an absurd Retry-After is clamped', () async {
      final service = await signedIn(
          recordingClient((_) => rateLimited(retryAfter: '99999999')));

      await service.refreshMe();

      expectBackoff(service.rateLimitBackoff('me'), PortalApi.maxRetryAfter);
    });

    test('logout does not retry a 429', () async {
      final service =
          await signedIn(recordingClient((_) => rateLimited(retryAfter: '300')));

      await service.logout();

      expect(requests.length, 1, reason: 'the retry would land in the block');
      expect(service.isSignedIn, isFalse);
    });

    test('a 429 on nonce backs the whole link lane off', () async {
      final service =
          await signedIn(recordingClient((_) => rateLimited(retryAfter: '120')));

      expect(await service.requestNonce('A' * 64), isNull);

      expectBackoff(service.linkLaneBackoff, const Duration(seconds: 120));
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

/// A store that cannot burn the pending pair. `SecureTokenStore` swallows its
/// own delete failures, but the service must not depend on that.
class _ThrowingDeletePendingStore extends InMemoryTokenStore {
  @override
  Future<void> deletePendingPkce() async =>
      throw StateError('keystore unavailable');
}
