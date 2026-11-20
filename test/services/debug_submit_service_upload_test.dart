import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mesh_mapper/services/debug_submit_service.dart';

/// A dropped upload answer followed by "Session Closed" means the file most
/// likely landed. The app lets upload-complete (and its hash check) decide
/// instead of failing the whole upload and never sending the user's notes.
void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('debug_submit_test');
    file = File('${dir.path}/debug_log.txt');
    await file.writeAsString('line one\nline two\n');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  http.Response json200(Map<String, dynamic> body) =>
      http.Response(json.encode(body), 200);

  final sessionBody = {
    'upload_url': 'https://meshmapper.net/debug/upload/abc',
    'session_id': 'abc',
    'expires_at': 0,
  };

  /// Builds a service whose server answers request-upload with a session,
  /// each upload attempt with the next entry of [uploads] (an exception is
  /// thrown, a response is returned), and upload-complete with [complete].
  ({DebugSubmitService service, List<String> calls, List<Object?> notes})
      build({
    required List<Object> uploads,
    required Map<String, dynamic> complete,
  }) {
    final calls = <String>[];
    final notes = <Object?>[];
    var uploadIndex = 0;
    final client = MockClient((request) async {
      final path = request.url.path;
      if (path.endsWith('/request-upload')) {
        calls.add('request');
        return json200(sessionBody);
      }
      if (path.endsWith('/upload-complete')) {
        calls.add('complete');
        notes.add((json.decode(request.body) as Map)['user_notes']);
        return json200(complete);
      }
      if (path.endsWith('/upload/abc')) {
        calls.add('upload');
        final next = uploads[uploadIndex++];
        if (next is Exception) throw next;
        return next as http.Response;
      }
      throw StateError('unexpected $path');
    });
    return (
      service: DebugSubmitService(
          client: client, retryDelayUnit: const Duration(milliseconds: 1)),
      calls: calls,
      notes: notes,
    );
  }

  Future<bool> upload(DebugSubmitService service) =>
      service.uploadDebugFileOnly(
        file: file,
        deviceId: 'dev',
        publicKey: 'AB' * 32,
        appVersion: '1.4.2',
        devicePlatform: 'ios',
        userNotes: 'my notes',
      );

  final sessionClosed =
      http.Response(json.encode({'message': 'Session Closed'}), 400);

  test('session closed after a dropped attempt goes on to upload-complete',
      () async {
    final h = build(
      uploads: [http.ClientException('connection reset'), sessionClosed],
      complete: {'success': true, 'hash_match': true},
    );

    expect(await upload(h.service), isTrue);
    expect(h.calls, ['request', 'upload', 'upload', 'complete']);
    expect(h.notes, ['my notes']);
  });

  test('that path still fails when upload-complete does not confirm',
      () async {
    final h = build(
      uploads: [http.ClientException('connection reset'), sessionClosed],
      complete: {'success': false, 'message': 'Hash mismatch'},
    );

    expect(await upload(h.service), isFalse);
    expect(h.calls, ['request', 'upload', 'upload', 'complete']);
  });

  // A closed session takes no more uploads, so retrying it only waits out
  // the backoff before failing anyway.
  test('session closed with no earlier dropped attempt fails at once',
      () async {
    final h = build(
      uploads: [sessionClosed, sessionClosed, sessionClosed],
      complete: {'success': true},
    );

    expect(await upload(h.service), isFalse);
    expect(h.calls, ['request', 'upload']);
  });

  test('session closed after a refusal fails without another attempt',
      () async {
    final h = build(
      uploads: [
        http.Response(json.encode({'message': 'Server error'}), 500),
        sessionClosed,
        sessionClosed,
      ],
      complete: {'success': true},
    );

    expect(await upload(h.service), isFalse);
    expect(h.calls, ['request', 'upload', 'upload']);
  });

  test('a plain successful upload is unchanged', () async {
    final h = build(
      uploads: [json200({'success': true})],
      complete: {'success': true},
    );

    expect(await upload(h.service), isTrue);
    expect(h.calls, ['request', 'upload', 'complete']);
  });

  group('request-upload retries a transport error', () {
    Future<UploadSession?> request(DebugSubmitService service) =>
        service.requestUpload(
          deviceId: 'dev',
          publicKey: 'AB' * 32,
          fileSizeBytes: 10,
          fileHash: '0' * 64,
          appVersion: '1.4.2',
          platform: 'ios',
        );

    test('a dropped first attempt is retried', () async {
      var calls = 0;
      final service = DebugSubmitService(
        client: MockClient((_) async {
          calls++;
          if (calls == 1) throw http.ClientException('connection reset');
          return json200(sessionBody);
        }),
        retryDelayUnit: const Duration(milliseconds: 1),
      );

      final session = await request(service);
      expect(session?.sessionId, 'abc');
      expect(calls, 2);
    });

    test('gives up after three attempts', () async {
      var calls = 0;
      final service = DebugSubmitService(
        client: MockClient((_) async {
          calls++;
          throw http.ClientException('connection reset');
        }),
        retryDelayUnit: const Duration(milliseconds: 1),
      );

      expect(await request(service), isNull);
      expect(calls, 3);
    });

    test('a server refusal is not retried', () async {
      var calls = 0;
      final service = DebugSubmitService(
        client: MockClient((_) async {
          calls++;
          return http.Response('{"message":"Bad"}', 400);
        }),
        retryDelayUnit: const Duration(milliseconds: 1),
      );

      expect(await request(service), isNull);
      expect(calls, 1);
    });
  });
}
