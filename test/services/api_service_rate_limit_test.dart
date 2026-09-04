import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// The server's storm brake answers more than 300 `/wardrive` posts per
/// session per minute with 429 `rate_limited` + `Retry-After` (75s by
/// default). The contract (APP_API.md, Appendix C item 9) is that a 429 keeps
/// the session valid and the client backs off; a client that lets its session
/// lapse and re-mints a fresh id defeats the brake.
///
/// Before this, a 429 on the keepalive set no retry at all: the heartbeat lane
/// went quiet, and if the car was stopped (no pings, no uploads to restart it)
/// the session expired, the next post got a 401 and the app force-disconnected
/// (VLC-20260903-0002: seven minutes of nothing but zone-status polls, then a
/// 401 and a fresh session two minutes later). Meanwhile the per-ping session
/// check and the batch upload kept posting straight through the penalty.
void main() {
  /// Mock server: every `/wardrive` post is counted; the first [rateLimited]
  /// of them answer 429 with the given Retry-After, the rest answer success.
  /// Each `/auth` mints a fresh session id, and expiry is stamped from the
  /// fake clock so the schedule math sees the same timeline the test elapses.
  ({ApiService api, List<DateTime> posts}) build({
    int rateLimited = 1,
    String? retryAfter = '75',
  }) {
    final posts = <DateTime>[];
    var auths = 0;
    final api = ApiService(
      client: MockClient((request) async {
        int expiresAt() => clock.now().millisecondsSinceEpoch ~/ 1000 + 300;
        if (request.url.path.endsWith('/auth')) {
          auths++;
          return http.Response(
            json.encode({
              'success': true,
              'session_id': 'VLC-20260903-000$auths',
              'tx_allowed': true,
              'rx_allowed': true,
              'expires_at': expiresAt(),
            }),
            200,
          );
        }
        posts.add(DateTime.now());
        if (posts.length <= rateLimited) {
          return http.Response(
            json.encode({
              'success': false,
              'reason': 'rate_limited',
              'message': 'Too many requests for this session',
            }),
            429,
            headers: {if (retryAfter != null) 'retry-after': retryAfter},
          );
        }
        return http.Response(
          json.encode({'success': true, 'expires_at': expiresAt()}),
          200,
        );
      }),
    );
    return (api: api, posts: posts);
  }

  void connect(FakeAsync async, ApiService api) {
    api.requestAuth(
      reason: 'connect',
      publicKey: 'AB',
      lat: 39.47,
      lon: -0.38,
    );
    async.flushMicrotasks();
  }

  test('a 429 on the keepalive comes back after Retry-After, not never', () {
    fakeAsync((async) {
      final built = build();
      connect(async, built.api);
      built.api.enableHeartbeat();
      async.flushMicrotasks();

      // The ordinary keepalive, 1 minute before the 300s expiry.
      async.elapse(const Duration(seconds: 241));
      expect(built.posts.length, 1, reason: 'the pre-expiry keepalive fires');
      expect(built.api.wardriveBackoff, isNotNull,
          reason: 'the 429 must leave a hold on the wardrive door');

      // Inside the penalty nothing goes out.
      async.elapse(const Duration(seconds: 70));
      expect(built.posts.length, 1,
          reason: 'no keepalive may be sent while Retry-After is running');

      // Once the penalty clears the lane resumes on its own.
      async.elapse(const Duration(seconds: 10));
      expect(built.posts.length, 2,
          reason: 'the heartbeat lane must come back after the server\'s '
              'Retry-After instead of going quiet until the session lapses');
      expect(built.api.wardriveBackoff, isNull);
    });
  });

  test('every wardrive sender holds while Retry-After runs', () {
    fakeAsync((async) {
      final built = build();
      connect(async, built.api);

      // The batch upload trips the brake.
      UploadResult? first;
      built.api.uploadBatch([
        {'type': 'RX', 'lat': 39.47, 'lon': -0.38}
      ]).then((r) => first = r);
      async.flushMicrotasks();
      expect(first, UploadResult.retryable,
          reason: 'a 429 is retryable: the queue keeps the batch');
      expect(built.posts.length, 1);

      // The per-ping session check does not knock on a closed door. The
      // session stays valid under a brake, so the ping itself may proceed.
      ({bool isValid, String? reason, String? message})? check;
      built.api.checkSessionValid().then((r) => check = r);
      async.flushMicrotasks();
      expect(check?.isValid, isTrue);
      expect(built.posts.length, 1,
          reason: 'a session check inside the penalty must not post');

      // Neither does the next batch: held, not a spent retry.
      UploadResult? second;
      built.api.uploadBatch([
        {'type': 'RX', 'lat': 39.47, 'lon': -0.38}
      ]).then((r) => second = r);
      async.flushMicrotasks();
      expect(second, UploadResult.held);
      expect(built.posts.length, 1,
          reason: 'a batch upload inside the penalty must not post');

      // After Retry-After both lanes post again.
      async.elapse(const Duration(seconds: 76));
      UploadResult? third;
      built.api.uploadBatch([
        {'type': 'RX', 'lat': 39.47, 'lon': -0.38}
      ]).then((r) => third = r);
      async.flushMicrotasks();
      expect(third, UploadResult.success);
      expect(built.posts.length, 2);
    });
  });

  test('a 429 without a usable Retry-After still backs off by the default', () {
    fakeAsync((async) {
      final built = build(retryAfter: null);
      connect(async, built.api);

      built.api.uploadBatch([
        {'type': 'RX', 'lat': 39.47, 'lon': -0.38}
      ]);
      async.flushMicrotasks();

      final hold = built.api.wardriveBackoff;
      expect(hold, isNotNull);
      expect(
          hold!.inSeconds,
          inInclusiveRange(ApiService.defaultWardriveRetryAfter.inSeconds - 1,
              ApiService.defaultWardriveRetryAfter.inSeconds));
    });
  });

  test('Retry-After parsing: delta-seconds, clamped, default on garbage', () {
    expect(ApiService.parseRetryAfter('75'), const Duration(seconds: 75));
    expect(ApiService.parseRetryAfter(' 120 '), const Duration(seconds: 120));
    expect(
        ApiService.parseRetryAfter('99999'), ApiService.maxWardriveRetryAfter);
    expect(
        ApiService.parseRetryAfter('0'), ApiService.defaultWardriveRetryAfter);
    expect(
        ApiService.parseRetryAfter('-5'), ApiService.defaultWardriveRetryAfter);
    expect(ApiService.parseRetryAfter('soon'),
        ApiService.defaultWardriveRetryAfter);
    expect(
        ApiService.parseRetryAfter(null), ApiService.defaultWardriveRetryAfter);
  });

  test('a fresh session starts with no hold', () {
    fakeAsync((async) {
      final built = build();
      connect(async, built.api);
      built.api.uploadBatch([
        {'type': 'RX', 'lat': 39.47, 'lon': -0.38}
      ]);
      async.flushMicrotasks();
      expect(built.api.wardriveBackoff, isNotNull);

      // The brake is per session id; a new session has a fresh bucket.
      connect(async, built.api);
      expect(built.api.wardriveBackoff, isNull,
          reason: 'a hold belongs to the session that earned it');
    });
  });
}
