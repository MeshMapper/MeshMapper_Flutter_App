import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/server_config.dart';
import 'package:mesh_mapper/services/server_probe.dart';

const _liveKey = 'live-key-for-tests';
const _customKey = 'custom-key-for-tests';

Future<String> _probe(
  MockClientHandler handler, {
  String domain = 'dev.example.org',
  String key = _customKey,
  Duration timeout = const Duration(seconds: 10),
}) =>
    probeServer(
      client: MockClient(handler),
      domain: domain,
      key: key,
      lat: 45.4,
      lon: -75.7,
      accuracyMeters: 5,
      appVersion: '1.0.0',
      timeout: timeout,
    );

MockClientHandler _answer(Object body, [int status = 200]) =>
    (request) async => http.Response(
        body is String ? body : jsonEncode(body), status);

void main() {
  setUp(() {
    ServerConfig.resetForTest();
    ServerConfig.buildKeyForTest = _liveKey;
  });
  tearDown(ServerConfig.resetForTest);

  test('asks the TYPED server with the TYPED key, not the active ones',
      () async {
    late http.Request sent;
    await _probe((request) async {
      sent = request;
      return http.Response('{"success":true,"in_zone":false}', 200);
    }, domain: 'https://Dev.Example.org/');
    expect(ServerConfig.isCustom, isFalse, reason: 'a test changes nothing');
    expect(sent.url.toString(),
        'https://dev.example.org/wardrive-api.php/status');
    final body = jsonDecode(sent.body) as Map<String, dynamic>;
    expect(body['key'], _customKey);
    expect(sent.body, isNot(contains(_liveKey)));
    expect(body.keys,
        containsAll(['lat', 'lng', 'accuracy_m', 'ver', 'timestamp', 'key']));
  });

  test('never sends anything for the live domain or a bad address', () async {
    var sent = 0;
    Future<http.Response> count(http.Request request) async {
      sent++;
      return http.Response('{}', 200);
    }

    expect(await _probe(count, domain: 'meshmapper.net'),
        contains('live server'));
    expect(await _probe(count, domain: 'http://dev.example.org'),
        contains('https'));
    expect(await _probe(count, domain: 'dev.example.org/x'),
        contains('host name'));
    expect(await _probe(count, key: '  '), contains('API key'));
    expect(sent, 0);
  });

  test('in a region', () async {
    expect(
      await _probe(_answer({
        'success': true,
        'in_zone': true,
        'zone': {'name': 'Ottawa', 'code': 'YOW'},
      })),
      'Working. dev.example.org accepted the key and places you in Ottawa '
      '(YOW).',
    );
  });

  test('outside every region', () async {
    expect(
      await _probe(_answer({
        'success': true,
        'in_zone': false,
        'nearest_zone': {'name': 'Montreal', 'distance_km': 12.34},
      })),
      'Working. dev.example.org accepted the key. You are outside every '
      'region there. The nearest is Montreal, 12.3 km away.',
    );
  });

  test('a refused key, by reason or by 401', () async {
    const words = 'dev.example.org answered, but this key is not valid there.';
    expect(
        await _probe(_answer({'success': false, 'reason': 'bad_key'})), words);
    expect(await _probe(_answer({'error': 'unauthorized'}, 401)), words);
  });

  test('maintenance', () async {
    expect(await _probe(_answer({'maintenance': true})),
        contains('maintenance mode'));
  });

  test('another refusal passes the server\'s own words on', () async {
    expect(
      await _probe(_answer({
        'success': false,
        'reason': 'gps_inaccurate',
        'message': 'GPS accuracy too low',
      })),
      'dev.example.org accepted the request but refused it: GPS accuracy too '
      'low',
    );
  });

  test('something that is not a MeshMapper server', () async {
    expect(await _probe(_answer('<html>hello</html>', 404)),
        'dev.example.org answered (HTTP 404), but not as a MeshMapper server.');
  });

  test('unreachable, a bad certificate, and no answer in time', () async {
    expect(
        await _probe((_) async => throw const SocketException('no route')),
        contains('Could not reach dev.example.org'));
    expect(
        await _probe(
            (_) async => throw const HandshakeException('bad certificate')),
        'The certificate of dev.example.org was not accepted.');
    expect(
        await _probe((_) => Completer<http.Response>().future,
            timeout: const Duration(milliseconds: 20)),
        contains('No answer from dev.example.org'));
  });

  test('no answer ever contains the key', () async {
    final answers = [
      await _probe(_answer({'success': false, 'reason': 'bad_key'})),
      await _probe(_answer({'success': true, 'in_zone': false})),
      await _probe((_) async => throw const SocketException('x')),
    ];
    for (final answer in answers) {
      expect(answer, isNot(contains(_customKey)));
    }
  });
}
