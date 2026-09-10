import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// The queue stamps every item with the auto mode running when it was
/// queued, and carries a DEFER item for each square where smart pinging
/// held a ping. No init(), so Hive stays closed and writes fall back to the
/// memory queue; extractAllAsJson() reads that back without clearing it.

void main() {
  ApiQueueService newQueue() => ApiQueueService(apiService: ApiService());

  test('every enqueue reads the mode getter at enqueue time', () async {
    final queue = newQueue();
    var mode = 'active';
    queue.autoModeGetter = () => mode;

    await queue.enqueueTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.25)',
      timestamp: 1757400000,
      externalAntenna: false,
    );
    mode = 'passive';
    await queue.enqueueDiscDrop(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: 1757400001,
      externalAntenna: false,
    );
    mode = 'trace';
    await queue.enqueueTrace(
      latitude: 45.0,
      longitude: -75.0,
      repeaterId: '4e2f',
      localSnr: 10.5,
      localRssi: -88,
      remoteSnr: 8.25,
      timestamp: 1757400002,
      externalAntenna: false,
    );

    final json = await queue.extractAllAsJson();
    expect(json.map((j) => j['auto_mode']), ['active', 'passive', 'trace']);
  });

  test('RX is stamped when buffered, not when flushed', () async {
    final queue = newQueue();
    var mode = 'hybrid';
    queue.autoModeGetter = () => mode;
    await queue.enqueueRx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.0)',
      timestamp: 1757400000,
      repeaterId: '4e',
      externalAntenna: false,
    );
    mode = 'none';
    // extractAllAsJson flushes the RX buffer into the queue first.
    final json = await queue.extractAllAsJson();
    expect(json.single['auto_mode'], 'hybrid');
  });

  test('no getter means no stamp', () async {
    final queue = newQueue();
    await queue.enqueueTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.25)',
      timestamp: 1757400000,
      externalAntenna: false,
    );
    final json = await queue.extractAllAsJson();
    expect(json.single.containsKey('auto_mode'), isFalse);
  });

  test('a deferral is queued as a five-field DEFER item', () async {
    final queue = newQueue();
    queue.autoModeGetter = () => 'active';
    var updates = 0;
    queue.onQueueUpdated = (_) => updates++;

    await queue.enqueueDefer(
      latitude: 45.26974,
      longitude: -75.77746,
      timestamp: 1757400000,
      held: 'tx',
    );

    expect(queue.queueSize, 1);
    expect(updates, 1);
    final json = await queue.extractAllAsJson();
    expect(json.single, {
      'type': 'DEFER',
      'lat': 45.26974,
      'lon': -75.77746,
      'timestamp': 1757400000,
      'held': 'tx',
    });
  });

  test('a DEFER survives the pre-disconnect snapshot and a session change',
      () async {
    final queue = newQueue();
    await queue.enqueueDefer(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: 1757400000,
      held: 'disc',
    );
    await queue.enqueueTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: 'None',
      timestamp: 1757400001,
      externalAntenna: false,
      pingCounter: 1,
      wireTag: 'MM:YVNPAr5OIw',
    );

    final preserved = await queue.extractAllAsJson();
    expect(preserved.map((j) => j['type']), ['DEFER'],
        reason: 'the tagged TX is left out, the DEFER is kept');

    await queue.dropStaleTaggedItems();
    expect(queue.queueSize, 1);
    final left = await queue.extractAllAsJson();
    expect(left.single['type'], 'DEFER');
  });

  group('offline mode', () {
    ApiQueueService offlineQueue() => newQueue()..offlineMode = true;

    test('appends the DEFER to the offline recording', () async {
      final queue = offlineQueue();
      await queue.enqueueDefer(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: 1757400000,
        held: 'tx',
      );
      expect(queue.offlinePingCount, 1);
      expect(queue.queueSize, 0);
    });

    test('the airborne pause drops it like any other offline row', () async {
      final queue = offlineQueue();
      queue.setOfflineRecordingPaused(true);
      await queue.enqueueDefer(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: 1757400000,
        held: 'tx',
      );
      expect(queue.offlinePingCount, 0);
    });
  });
}
