import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Airborne block, Offline Mode: an offline upload is the one path that could
/// carry in-flight rows to the server after the forced app upgrade, so while
/// the airborne latch is set no accepted fix may be appended to the offline
/// recording. The online queue needs nothing here: the session end drops it.

void main() {
  ApiQueueService newOfflineQueue() =>
      // No init(), so Hive stays closed; offline rows live in memory anyway.
      ApiQueueService(apiService: ApiService())..offlineMode = true;

  Future<void> enqueueTx(ApiQueueService queue) => queue.enqueueTx(
        latitude: 45.26974,
        longitude: -75.77746,
        heardRepeats: '4e(12.25)',
        timestamp: 1750000000,
        externalAntenna: false,
      );

  Future<void> enqueueRx(ApiQueueService queue) => queue.enqueueRx(
        latitude: 45.26974,
        longitude: -75.77746,
        heardRepeats: '4e(12.25)',
        timestamp: 1750000000,
        repeaterId: '4e',
        externalAntenna: false,
      );

  test('rows are dropped while paused and accepted again after resume',
      () async {
    final queue = newOfflineQueue();
    await enqueueTx(queue);
    expect(queue.offlinePingCount, 1);

    queue.setOfflineRecordingPaused(true);
    expect(queue.isOfflineRecordingPaused, isTrue);
    await enqueueTx(queue);
    await enqueueRx(queue);
    expect(queue.offlinePingCount, 1,
        reason: 'nothing recorded while the latch is set');

    queue.setOfflineRecordingPaused(false);
    expect(queue.isOfflineRecordingPaused, isFalse);
    await enqueueRx(queue);
    expect(queue.offlinePingCount, 2);
  });

  test('a repeated pause or resume is a no-op', () {
    final queue = newOfflineQueue();
    queue.setOfflineRecordingPaused(false);
    expect(queue.isOfflineRecordingPaused, isFalse);
    queue.setOfflineRecordingPaused(true);
    queue.setOfflineRecordingPaused(true);
    expect(queue.isOfflineRecordingPaused, isTrue);
  });
}
