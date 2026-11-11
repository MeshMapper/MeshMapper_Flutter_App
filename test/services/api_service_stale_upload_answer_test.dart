import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// An upload refusal is about the session the batch was sent under. A
/// Disconnect now uploads the queue before it releases the session, and on a
/// slow network that POST can still be out when the release lands, or when
/// the user has already reconnected. Its `bad_session` answer used to clear
/// whatever session was current and fire the session-error disconnect, so a
/// stale answer for the old session tore down the new connection.
void main() {
  ({ApiService api, Completer<void> gate, List<String> errors}) build() {
    var auths = 0;
    final gate = Completer<void>();
    final errors = <String>[];
    final api = ApiService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('/auth')) {
          auths++;
          return http.Response(
            json.encode({
              'success': true,
              'session_id': 'session-$auths',
              'tx_allowed': true,
              'rx_allowed': true,
              'expires_at':
                  DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            }),
            200,
          );
        }
        await gate.future;
        return http.Response(
          json.encode({
            'success': false,
            'reason': 'bad_session',
            'message': 'closed for test',
          }),
          401,
        );
      }),
    );
    api.onSessionError = (reason, message, {subReason}) async {
      errors.add(reason ?? 'null');
    };
    return (api: api, gate: gate, errors: errors);
  }

  Future<void> connect(ApiService api) => api.requestAuth(
        reason: 'connect',
        publicKey: 'AB',
        lat: 45.0,
        lon: -75.0,
      );

  final batch = [
    {'type': 'RX', 'lat': 45.0, 'lon': -75.0}
  ];

  test('a refusal for a released session is ignored', () async {
    final built = build();
    await connect(built.api);

    final upload = built.api.uploadBatch(batch);
    built.api.clearSession();
    built.gate.complete();

    expect(await upload, UploadResult.held);
    expect(built.errors, isEmpty);
  });

  test('a refusal for a replaced session leaves the new one alone', () async {
    final built = build();
    await connect(built.api);
    expect(built.api.sessionId, 'session-1');

    final upload = built.api.uploadBatch(batch);
    await connect(built.api);
    built.gate.complete();

    expect(await upload, UploadResult.held);
    expect(built.api.sessionId, 'session-2');
    expect(built.errors, isEmpty);
  });

  test('a refusal for the current session still ends it', () async {
    final built = build();
    await connect(built.api);
    built.gate.complete();

    expect(await built.api.uploadBatch(batch), UploadResult.nonRetryable);
    expect(built.api.sessionId, isNull);
    expect(built.errors, ['bad_session']);
  });
}
