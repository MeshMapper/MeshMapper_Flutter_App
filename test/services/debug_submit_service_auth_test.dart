import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/debug_file_logger.dart';
import 'package:mesh_mapper/services/debug_submit_service.dart';

/// The debug-log upload and the bug report carry the app key on every call,
/// and each upload session's token on its upload and upload-complete, always
/// in the body. A 401 is final: the server's message is kept and nothing is
/// retried. Contract: MeshMapper_Server/docs/APP_API.md, appendix A.
void main() {
  const apiKey = 'TEST-APP-KEY';
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('debug_submit_auth_test');
    file = File('${dir.path}/debug_log.txt');
    await file.writeAsString('line one\nline two\n');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  http.Response answer(Map<String, dynamic> body, [int status = 200]) =>
      http.Response(json.encode(body), status);

  final refusal = answer({
    'success': false,
    'message': 'This app build is not allowed to send reports.',
  }, 401);

  String routeOf(http.BaseRequest request) {
    final path = request.url.path;
    if (path.endsWith('/create-ticket')) return 'ticket';
    if (path.endsWith('/request-upload')) return 'request';
    if (path.endsWith('/upload-complete')) return 'complete';
    if (path.contains('/upload/')) return 'upload';
    throw StateError('unexpected $path');
  }

  /// A server that hands out token-1, token-2, ... per session and records
  /// what each call carried. [refuse] names a route that answers 401.
  ({
    DebugSubmitService service,
    List<String> calls,
    List<Map<String, dynamic>> bodies,
    List<Uri> urls,
  }) build({String? refuse, bool handOutTokens = true}) {
    final calls = <String>[];
    final bodies = <Map<String, dynamic>>[];
    final urls = <Uri>[];
    var sessions = 0;
    final client = MockClient.streaming((request, bodyStream) async {
      final route = routeOf(request);
      calls.add(route);
      urls.add(request.url);
      final raw = await bodyStream.bytesToString();
      if (request is http.MultipartRequest) {
        bodies.add(Map<String, dynamic>.from(request.fields));
      } else {
        bodies.add(json.decode(raw) as Map<String, dynamic>);
      }
      http.StreamedResponse send(http.Response r) => http.StreamedResponse(
          Stream.value(r.bodyBytes), r.statusCode,
          headers: r.headers);
      if (route == refuse) return send(refusal);
      switch (route) {
        case 'ticket':
          return send(answer({
            'success': true,
            'issue_number': 7,
            'issue_url': 'https://example.test/issues/7',
          }));
        case 'request':
          sessions++;
          return send(answer({
            'upload_url': 'https://meshmapper.net/debug/submitdebug.php'
                '/upload/?session_id=s$sessions',
            'session_id': 's$sessions',
            'expires_at': 0,
            if (handOutTokens) 'upload_token': 'token-$sessions',
          }));
        case 'upload':
          return send(answer({'success': true}));
        default:
          return send(answer({'success': true, 'hash_match': true}));
      }
    });
    return (
      service: DebugSubmitService(
        client: client,
        retryDelayUnit: const Duration(milliseconds: 1),
        apiKey: apiKey,
      ),
      calls: calls,
      bodies: bodies,
      urls: urls,
    );
  }

  Future<bool> upload(DebugSubmitService service, [File? which]) =>
      service.uploadDebugFileOnly(
        file: which ?? file,
        deviceId: 'dev',
        publicKey: 'AB' * 32,
        appVersion: '1.4.3',
        devicePlatform: 'ios',
        userNotes: 'my notes',
      );

  Future<BugReportResult> report(DebugSubmitService service,
          {List<File>? files}) =>
      service.submitBugReport(
        title: 'Crash',
        body: 'It crashed',
        platform: 'app',
        ticketType: 'bug',
        deviceId: 'dev',
        publicKey: 'AB' * 32,
        appVersion: '1.4.3',
        devicePlatform: 'ios',
        debugFiles: files,
      );

  void expectNothingInAddress(List<Uri> urls) {
    for (final url in urls) {
      expect(url.toString(), isNot(contains(apiKey)));
      expect(url.toString(), isNot(contains('token-')));
      expect(url.queryParameters.keys,
          isNot(anyOf(contains('key'), contains('upload_token'))));
    }
  }

  test('all four calls carry the key, upload and complete carry the token',
      () async {
    final h = build();

    final result = await report(h.service, files: [file]);

    expect(result.success, isTrue);
    expect(result.uploadedFileCount, 1);
    expect(h.calls, ['ticket', 'request', 'upload', 'complete']);
    for (final body in h.bodies) {
      expect(body['key'], apiKey);
    }
    expect(h.bodies[0].containsKey('upload_token'), isFalse);
    expect(h.bodies[1].containsKey('upload_token'), isFalse);
    expect(h.bodies[2]['upload_token'], 'token-1');
    expect(h.bodies[3]['upload_token'], 'token-1');
    expect(h.bodies[3]['session_id'], 's1');
    expectNothingInAddress(h.urls);
  });

  test('each piece of a split file uses its own token', () async {
    // Over the 4.5 MB piece limit, so it is split in two.
    final big = File('${dir.path}/big_log.txt');
    final line = '${'x' * 99}\n';
    final sink = big.openWrite();
    for (var i = 0; i < 60000; i++) {
      sink.write(line);
    }
    await sink.close();
    // The splitter writes its pieces to the platform's temp folder.
    TestWidgetsFlutterBinding.ensureInitialized();
    const pathProvider = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(pathProvider, (_) async => dir.path);
    addTearDown(() => messenger.setMockMethodCallHandler(pathProvider, null));
    final pieces = await DebugFileLogger.splitFileIntoChunks(big);
    expect(pieces.length, 2);
    await DebugFileLogger.cleanupChunkFiles(pieces);
    final h = build();

    expect(await upload(h.service, big), isTrue);

    expect(h.calls,
        ['request', 'upload', 'complete', 'request', 'upload', 'complete']);
    expect(h.bodies[1]['upload_token'], 'token-1');
    expect(h.bodies[2]['upload_token'], 'token-1');
    expect(h.bodies[4]['upload_token'], 'token-2');
    expect(h.bodies[5]['upload_token'], 'token-2');
    expect(h.bodies[5]['session_id'], 's2');
    expectNothingInAddress(h.urls);
  });

  test('a server that hands out no token still gets the upload', () async {
    final h = build(handOutTokens: false);

    expect(await upload(h.service), isTrue);

    expect(h.calls, ['request', 'upload', 'complete']);
    expect(h.bodies[1]['key'], apiKey);
    expect(h.bodies[1].containsKey('upload_token'), isFalse);
    expect(h.bodies[2].containsKey('upload_token'), isFalse);
  });

  group('a 401 shows the server message and is not retried', () {
    const message = 'This app build is not allowed to send reports.';

    test('on create-ticket', () async {
      final h = build(refuse: 'ticket');

      final result = await report(h.service, files: [file]);

      expect(result.success, isFalse);
      expect(result.errorMessage, message);
      expect(h.calls, ['ticket']);
    });

    test('on request-upload', () async {
      final h = build(refuse: 'request');

      expect(await upload(h.service), isFalse);
      expect(h.service.refusalMessage, message);
      expect(h.calls, ['request']);
    });

    test('on upload', () async {
      final h = build(refuse: 'upload');

      expect(await upload(h.service), isFalse);
      expect(h.service.refusalMessage, message);
      expect(h.calls, ['request', 'upload']);
    });

    test('on upload-complete', () async {
      final h = build(refuse: 'complete');

      expect(await upload(h.service), isFalse);
      expect(h.service.refusalMessage, message);
      expect(h.calls, ['request', 'upload', 'complete']);
    });

    test('a refused log upload skips the other files of a bug report',
        () async {
      final second = File('${dir.path}/second_log.txt');
      await second.writeAsString('more\n');
      final h = build(refuse: 'request');

      final result = await report(h.service, files: [file, second]);

      expect(result.success, isTrue, reason: 'the ticket was created');
      expect(result.failedFileCount, 2);
      expect(result.errorMessage, message);
      expect(h.calls, ['ticket', 'request']);
    });

    test('the next upload starts clean', () async {
      final h = build(refuse: 'upload');
      expect(await upload(h.service), isFalse);

      final ok = build();
      expect(await upload(ok.service), isTrue);
      expect(ok.service.refusalMessage, isNull);
    });
  });
}
