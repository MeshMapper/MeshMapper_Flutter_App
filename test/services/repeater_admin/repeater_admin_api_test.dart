import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/repeater_admin/repeater_admin_api.dart';

/// Request shapes pinned by MeshMapper_Server/docs/HANDOFF-repeater-administrators-server.md.
void main() {
  http.Request? seen;
  String? sessionId = 'YOW-20260910-0001';

  RepeaterAdminApi api(http.Response Function(http.Request) responder) =>
      RepeaterAdminApi(
        client: MockClient((request) async {
          seen = request;
          return responder(request);
        }),
        sessionId: () => sessionId,
        appVersion: () => '1.4.0',
      );

  http.Response ok(Map<String, dynamic> body) =>
      http.Response(json.encode({'success': true, ...body}), 200);

  setUp(() {
    seen = null;
    sessionId = 'YOW-20260910-0001';
  });

  Map<String, dynamic> body() =>
      json.decode(seen!.body) as Map<String, dynamic>;

  test('claim posts the envelope, action, repeater and proof', () async {
    final result = await api((_) => ok({
          'administrators': ['Alice', 'Bob'],
          'claimed_at': 10,
          'updated_at': 20,
        })).claim('ab' * 32, {
      'login': 'admin',
      'acl': true,
      'perms': 3,
      'fw_level': 2
    });
    expect(seen!.url.toString(), RepeaterAdminApi.endpoint);
    expect(seen!.headers['content-type'], startsWith('application/json'));
    final b = body();
    expect(b['session_id'], 'YOW-20260910-0001');
    expect(b['action'], 'claim');
    expect(b['app_ver'], '1.4.0');
    expect(b['repeater'], 'AB' * 32);
    expect(
        b['proof'], {'login': 'admin', 'acl': true, 'perms': 3, 'fw_level': 2});
    expect(b.keys.toSet().intersection(RepeaterAdminApi.forbiddenTopLevelKeys),
        isEmpty);
    expect(result.ok, isTrue);
    expect(result.administrators, ['Alice', 'Bob']);
    expect(result.claimedAt, 10);
  });

  test('unclaim', () async {
    final result =
        await api((_) => ok({'administrators': []})).unclaim('ab' * 32);
    expect(body()['action'], 'unclaim');
    expect(result.ok, isTrue);
    expect(result.administrators, isEmpty);
  });

  test('mine parses claims and drops bad rows', () async {
    final result = await api((_) => ok({
          'claims': [
            {
              'repeater': 'cd' * 32,
              'name': 'Hill',
              'iata': 'YOW',
              'claimed_at': 1,
              'updated_at': 2
            },
            {'repeater': 'nope'},
          ]
        })).mine();
    expect(body()['action'], 'mine');
    expect(body().containsKey('repeater'), isFalse);
    expect(result.claims.single.repeaterHex, 'CD' * 32);
  });

  test('neighbours ride under the neighbours key, never data', () async {
    final table = {
      'fetched_at': 1700000000,
      'total': 1,
      'entries': [
        {'prefix': 'AB' * 8, 'snr': -3.0, 'heard_secs_ago': 60}
      ],
    };
    final result = await api((_) => ok({
          'administrators': ['A'],
          'resolved': 1,
          'unresolved': 0
        })).neighbours('ab' * 32, table);
    final b = body();
    expect(b['action'], 'neighbours');
    expect(b['neighbours'], table);
    expect(b.containsKey('data'), isFalse);
    expect(result.resolved, 1);
  });

  test('an old server answers 400 invalid_request, mapped to unsupported',
      () async {
    final result = await api((_) => http.Response(
        json.encode(
            {'success': false, 'reason': 'invalid_request', 'message': 'x'}),
        400)).claim('ab' * 32, {});
    expect(result.ok, isFalse);
    expect(result.failure, RepeaterAdminFailureKind.unsupported);
    expect(result.userMessage, 'This region does not support claiming yet.');
  });

  test('reason unsupported is also unsupported', () async {
    final result = await api((_) => http.Response(
        json.encode({'success': false, 'reason': 'unsupported'}), 400)).mine();
    expect(result.failure, RepeaterAdminFailureKind.unsupported);
  });

  test('429 carries Retry-After', () async {
    final result = await api((_) => http.Response(
        json.encode({'success': false, 'reason': 'rate_limited'}), 429,
        headers: {'retry-after': '120'})).claim('ab' * 32, {});
    expect(result.failure, RepeaterAdminFailureKind.rateLimited);
    expect(result.retryAfter, const Duration(seconds: 120));
    expect(result.userMessage, 'Too many requests. Try again in 2 minutes.');
  });

  test('the named refusals map by reason', () async {
    Future<RepeaterAdminFailureKind> kind(int status, String reason) async =>
        (await api((_) => http.Response(
                    json.encode({'success': false, 'reason': reason}), status))
                .claim('ab' * 32, {}))
            .failure;
    expect(await kind(403, 'not_admin'), RepeaterAdminFailureKind.notAdmin);
    expect(await kind(403, 'no_claim'), RepeaterAdminFailureKind.noClaim);
    expect(await kind(404, 'unknown_repeater'),
        RepeaterAdminFailureKind.unknownRepeater);
    expect(await kind(409, 'too_many_admins'),
        RepeaterAdminFailureKind.tooManyAdmins);
    expect(await kind(401, 'session_expired'),
        RepeaterAdminFailureKind.sessionExpired);
    expect(await kind(400, 'invalid'), RepeaterAdminFailureKind.invalid);
  });

  test('no session makes no request', () async {
    sessionId = null;
    final result = await api((_) => ok({})).mine();
    expect(seen, isNull);
    expect(result.failure, RepeaterAdminFailureKind.noSession);
  });

  test('a thrown client error is network', () async {
    final result = await api((_) => throw Exception('boom')).mine();
    expect(result.failure, RepeaterAdminFailureKind.network);
  });

  test('a non-JSON body is invalid', () async {
    final result = await api((_) => http.Response('<html>', 502)).mine();
    expect(result.failure, RepeaterAdminFailureKind.invalid);
  });

  test('a bad key shape is refused locally', () async {
    final result = await api((_) => ok({})).claim('nope', {});
    expect(seen, isNull);
    expect(result.failure, RepeaterAdminFailureKind.invalid);
  });
}
