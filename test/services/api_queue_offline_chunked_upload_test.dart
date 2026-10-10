import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/offline_session_service.dart';

/// `runOfflineChunkedUpload` is the orchestration `app_state_provider.dart`'s
/// offline upload delegates to (review round 1, finding 5: no
/// `AppStateProvider` harness exists in this repo, so the piece that
/// actually carries the bug risk is extracted here and tested directly):
/// strip SCOPES rows the upload auth cannot accept, move every remaining
/// SCOPES row after every other row (DISC before SCOPES), persist that
/// final order BEFORE the first chunk is built, then upload fixed-size
/// chunks in order, stopping at the first one that does not succeed.
///
/// Persisting before chunking is the point (finding 2): the caller's later
/// partial-upload cleanup removes a PREFIX of the STORED rows by uploaded
/// count, and that prefix only lines up with what was actually sent when
/// the file already holds the same order that was chunked. These tests
/// drive a REAL `OfflineSessionService` (SharedPreferences-backed) and
/// re-read it through a FRESH instance, so persistence is proven after a
/// reload, not merely against the instance that wrote it.
///
/// Forwarding to the custom API is decided by `runOfflineChunkedUpload`
/// itself (its `forwardChunk` sink, which the provider wires to the custom
/// API forward), never by the test's upload callback, so a regression in
/// what production forwards shows up here.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Map<String, dynamic> row(String type, int seq) => {'type': type, 'seq': seq};

  /// Reads the stored session back through a FRESH service instance, so
  /// what is checked is what reached SharedPreferences, not the calling
  /// instance's memory.
  Future<List<dynamic>> storedPings(String filename) async {
    final reloaded = OfflineSessionService();
    await reloaded.init();
    return reloaded.getSession(filename)!.data['pings'] as List<dynamic>;
  }

  test(
      'key absent: the stored file is already stripped and reordered when '
      'the first chunk goes out, chunk 1 succeeds and chunk 2 fails, the '
      'retained rows are exactly the unsent ones, and only chunk 1 is '
      'forwarded, once', () async {
    SharedPreferences.setMockInitialValues({});
    final service = OfflineSessionService();
    await service.init();

    final stored = [
      row('SCOPES', 0),
      row('RX', 1),
      row('DISC', 2),
      row('SCOPES', 3),
      row('RX', 4),
      row('RX', 5),
    ];
    await service.updateCurrentSession(stored, deviceName: 'Test');
    final filename = service.sessions.single.filename;

    final forwarded = <int, List<Map<String, dynamic>>>{};
    final forwardOrder = <int>[];
    final uploadCalls = <int>[];
    List<dynamic>? storedAtFirstChunk;

    final result = await runOfflineChunkedUpload(
      stored,
      scopeDiscoveryOffered: false, // the key was absent
      batchSize: 2,
      persistRows: (ordered) => service.replacePings(filename, ordered),
      uploadChunk: (chunk, chunkNumber, totalChunks) async {
        uploadCalls.add(chunkNumber);
        if (chunkNumber == 1) {
          // The moment the first chunk is sent, the stored file must
          // already hold exactly the list being chunked.
          storedAtFirstChunk = await storedPings(filename);
          return true;
        }
        return false; // the second chunk fails
      },
      forwardChunk: (chunk, chunkNumber) {
        forwardOrder.add(chunkNumber);
        forwarded[chunkNumber] = chunk;
      },
    );

    final expectedOrder = [row('RX', 1), row('DISC', 2), row('RX', 4), row('RX', 5)];
    expect(storedAtFirstChunk, expectedOrder,
        reason: 'stripped before the first chunk was sent');
    expect(result.removedScopesCount, 2);
    expect(result.orderedRows, expectedOrder);

    expect(uploadCalls, [1, 2]);
    expect(result.uploadedCount, 2);
    expect(forwardOrder, [1], reason: 'forwarded once, and only chunk 1');
    expect(forwarded[1], [row('RX', 1), row('DISC', 2)]);

    // What app_state_provider.dart does next: prune the uploaded prefix by
    // count against the stored (already reordered) file.
    await service.removeProcessedPings(filename, result.uploadedCount);
    final retained = await storedPings(filename);
    expect(retained, [row('RX', 4), row('RX', 5)],
        reason: 'retained rows are exactly the ones not uploaded');

    // Nothing retained was forwarded, and nothing forwarded is retained.
    final forwardedRows = forwarded.values.expand((c) => c).toList();
    for (final r in retained) {
      expect(forwardedRows, isNot(contains(r)));
    }
  });

  test(
      'key present: SCOPES are kept but moved after every other row, and '
      'the stored file already holds that order when the first chunk goes '
      'out; a failing middle chunk stops the upload and nothing after it is '
      'sent or forwarded', () async {
    SharedPreferences.setMockInitialValues({});
    final service = OfflineSessionService();
    await service.init();

    final stored = [
      row('SCOPES', 0),
      row('DISC', 1),
      row('RX', 2),
      row('SCOPES', 3),
      row('DISC', 4),
    ];
    await service.updateCurrentSession(stored, deviceName: 'Test');
    final filename = service.sessions.single.filename;

    final forwardOrder = <int>[];
    final forwardedRows = <Map<String, dynamic>>[];
    final uploadCalls = <int>[];
    List<dynamic>? storedAtFirstChunk;

    final result = await runOfflineChunkedUpload(
      stored,
      scopeDiscoveryOffered: true, // the key was present
      batchSize: 2,
      persistRows: (ordered) => service.replacePings(filename, ordered),
      uploadChunk: (chunk, chunkNumber, totalChunks) async {
        uploadCalls.add(chunkNumber);
        if (chunkNumber == 1) {
          storedAtFirstChunk = await storedPings(filename);
        }
        return chunkNumber == 1;
      },
      forwardChunk: (chunk, chunkNumber) {
        forwardOrder.add(chunkNumber);
        forwardedRows.addAll(chunk);
      },
    );

    final expectedOrder = [
      row('DISC', 1),
      row('RX', 2),
      row('DISC', 4),
      row('SCOPES', 0),
      row('SCOPES', 3),
    ];
    expect(result.removedScopesCount, 0);
    expect(storedAtFirstChunk, expectedOrder);
    expect(result.orderedRows, expectedOrder);
    expect(uploadCalls, [1, 2], reason: 'chunk 3 is never attempted');
    expect(forwardOrder, [1]);
    expect(forwardedRows, [row('DISC', 1), row('RX', 2)]);

    await service.removeProcessedPings(filename, result.uploadedCount);
    expect(await storedPings(filename),
        [row('DISC', 4), row('SCOPES', 0), row('SCOPES', 3)]);
  });

  test('every chunk succeeds: each is forwarded exactly once, in order',
      () async {
    final stored = [row('DISC', 0), row('SCOPES', 1), row('RX', 2)];
    final forwardOrder = <int>[];
    final forwardedRows = <Map<String, dynamic>>[];

    final result = await runOfflineChunkedUpload(
      stored,
      scopeDiscoveryOffered: true,
      batchSize: 2,
      persistRows: (ordered) async {},
      uploadChunk: (chunk, chunkNumber, totalChunks) async => true,
      forwardChunk: (chunk, chunkNumber) {
        forwardOrder.add(chunkNumber);
        forwardedRows.addAll(chunk);
      },
    );

    expect(result.uploadedCount, 3);
    expect(forwardOrder, [1, 2]);
    expect(forwardedRows, [row('DISC', 0), row('RX', 2), row('SCOPES', 1)]);
  });

  test('no SCOPES rows at all: persistRows is never called (nothing to '
      'strip or reorder, the stored order already matches)', () async {
    var persistCalls = 0;
    final stored = [row('TX', 0), row('RX', 1)];

    final result = await runOfflineChunkedUpload(
      stored,
      scopeDiscoveryOffered: false,
      batchSize: 50,
      persistRows: (ordered) async => persistCalls++,
      uploadChunk: (chunk, chunkNumber, totalChunks) async => true,
      forwardChunk: (chunk, chunkNumber) {},
    );

    expect(persistCalls, 0);
    expect(result.orderedRows, stored);
    expect(result.uploadedCount, 2);
    expect(result.removedScopesCount, 0);
  });

  test('a stored row with a bare altitude loses it before upload and forward, '
      'a labelled row keeps the trio', () async {
    final uploaded = <Map<String, dynamic>>[];
    final forwarded = <Map<String, dynamic>>[];
    final result = await runOfflineChunkedUpload(
      [
        {'type': 'TX', 'lat': 45.0, 'lon': -75.0, 'altitude': 84},
        {
          'type': 'RX',
          'lat': 45.0,
          'lon': -75.0,
          'altitude': 90,
          'altitude_ref': 'msl',
          'altitude_acc': 4,
        },
        {
          'type': 'TX',
          'lat': 45.0,
          'lon': -75.0,
          'altitude': 91,
          'altitude_ref': 'bogus',
        },
      ],
      scopeDiscoveryOffered: true,
      batchSize: 50,
      persistRows: (_) async {},
      uploadChunk: (chunk, _, __) async {
        uploaded.addAll(chunk);
        return true;
      },
      forwardChunk: (chunk, _) => forwarded.addAll(chunk),
    );
    expect(result.uploadedCount, 3);
    for (final rows in [uploaded, forwarded]) {
      expect(rows[0].containsKey('altitude'), isFalse);
      expect(rows[0].containsKey('altitude_ref'), isFalse);
      expect(rows[1]['altitude'], 90);
      expect(rows[1]['altitude_ref'], 'msl');
      expect(rows[1]['altitude_acc'], 4);
      expect(rows[2].containsKey('altitude'), isFalse,
          reason: 'an unknown reference word is as good as none');
      expect(rows[2].containsKey('altitude_ref'), isFalse);
    }
  });
}
