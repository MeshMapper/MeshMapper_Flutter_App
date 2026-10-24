import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Sends every request to a local server instead of meshmapper.net, keeping
/// the abort trigger so the real IOClient abort path runs.
class _LocalClient extends http.BaseClient {
  final Uri base;
  final IOClient inner = IOClient(HttpClient());
  int sent = 0;

  _LocalClient(this.base);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    sent++;
    final trigger = request is http.Abortable ? request.abortTrigger : null;
    final local = http.AbortableRequest(
        request.method, base.replace(path: request.url.path),
        abortTrigger: trigger)
      ..headers.addAll(request.headers)
      ..bodyBytes = request is http.Request ? request.bodyBytes : const [];
    return inner.send(local);
  }

  @override
  void close() => inner.close();
}

void main() {
  HttpServer? server;
  late _LocalClient client;

  tearDown(() async {
    client.close();
    await server?.close(force: true);
  });

  test('a slow /border body is aborted at the timeout, not left downloading',
      () async {
    // A raw socket, because HttpServer does not report the client hanging up.
    final hungUp = Completer<void>();
    final raw = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    var connections = 0;
    raw.listen((socket) async {
      if (++connections > 1) {
        // The follow-up request: a small, complete answer.
        final body = json.encode({
          'success': true,
          'polygons': [
            {
              'code': 'AKL',
              'polygon': [
                [1, 2],
                [3, 4],
              ],
            },
          ],
        });
        socket.listen((_) {}, onError: (_) {});
        socket.write('HTTP/1.1 200 OK\r\n'
            'Content-Type: application/json\r\n'
            'Content-Length: ${body.length}\r\n\r\n$body');
        await socket.flush();
        await socket.close();
        return;
      }
      socket.listen((_) {}, onDone: () {
        if (!hungUp.isCompleted) hungUp.complete();
      }, onError: (_) {
        if (!hungUp.isCompleted) hungUp.complete();
      });
      // Headers for a 4.8 MB body, then a dribble of it, like a group border
      // over a slow mobile link.
      socket.write('HTTP/1.1 200 OK\r\n'
          'Content-Type: application/json\r\n'
          'Content-Length: 4800000\r\n\r\n{"polygons":[');
      try {
        while (!hungUp.isCompleted) {
          socket.write('{"code":"AKL","polygon":[[1,2],[3,4]]},');
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } catch (_) {}
      await socket.close();
    });
    addTearDown(raw.close);
    client = _LocalClient(Uri.parse('http://127.0.0.1:${raw.port}'));
    final api = ApiService(
        client: client, borderTimeout: const Duration(milliseconds: 300));

    final stopwatch = Stopwatch()..start();
    final result = await api.fetchBorderPolygons(
        lat: -36.85, lon: 174.76, appVersion: 'APP-TEST');
    stopwatch.stop();

    expect(result, isNull);
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)));
    expect(client.sent, 1);
    // The phone closed the connection: the download really stopped.
    await hungUp.future.timeout(const Duration(seconds: 5));

    // The aborted connection is not reused: the same client asks again and
    // gets a whole answer.
    final again = await api
        .fetchBorderPolygons(lat: -36.85, lon: 174.76, appVersion: 'APP-TEST')
        .timeout(const Duration(seconds: 5));
    expect(again!.polygons.single['code'], 'AKL');
    expect(client.sent, 2);
    expect(connections, 2);
  });

  test('a /border answer within the allowance is parsed', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) async {
      request.response
        ..headers.contentType = ContentType.json
        ..write(json.encode({
          'success': true,
          'border_hash': 'abc123',
          'polygons': [
            {
              'code': 'AKL',
              'polygon': [
                [1, 2],
                [3, 4],
              ],
            },
          ],
        }));
      await request.response.close();
    });
    client = _LocalClient(Uri.parse('http://127.0.0.1:${server!.port}'));
    final api = ApiService(client: client);

    final result = await api.fetchBorderPolygons(
        lat: -36.85, lon: 174.76, appVersion: 'APP-TEST');

    expect(result!.polygons, hasLength(1));
    expect(result.polygons.first['code'], 'AKL');
    expect(result.borderHash, 'abc123');
  });

  test('an answer without border_hash is returned with no hash', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) async {
      request.response
        ..headers.contentType = ContentType.json
        ..write(json.encode({
          'success': true,
          'border_hash': '',
          'polygons': [
            {'code': 'AKL', 'polygon': []},
          ],
        }));
      await request.response.close();
    });
    client = _LocalClient(Uri.parse('http://127.0.0.1:${server!.port}'));
    final api = ApiService(client: client);

    final result = await api.fetchBorderPolygons(
        lat: -36.85, lon: 174.76, appVersion: 'APP-TEST');

    expect(result!.polygons, hasLength(1));
    expect(result.borderHash, isNull);
  });

  test('a 503 border_unavailable is a failure', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((request) async {
      request.response
        ..statusCode = 503
        ..headers.contentType = ContentType.json
        ..headers.set('Retry-After', '300')
        ..write(json.encode({
          'success': false,
          'reason': 'border_unavailable',
        }));
      await request.response.close();
    });
    client = _LocalClient(Uri.parse('http://127.0.0.1:${server!.port}'));
    final api = ApiService(client: client);

    final result = await api.fetchBorderPolygons(
        lat: -36.85, lon: 174.76, appVersion: 'APP-TEST');

    expect(result, isNull);
    expect(client.sent, 1);
  });

  test('a server that never answers the headers is aborted too', () async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server!.listen((_) {});
    client = _LocalClient(Uri.parse('http://127.0.0.1:${server!.port}'));
    final api = ApiService(
        client: client, borderTimeout: const Duration(milliseconds: 300));

    final result = await api
        .fetchBorderPolygons(lat: -36.85, lon: 174.76, appVersion: 'APP-TEST')
        .timeout(const Duration(seconds: 5));

    expect(result, isNull);
    // An abort is never sent again.
    expect(client.sent, 1);
  });
}
