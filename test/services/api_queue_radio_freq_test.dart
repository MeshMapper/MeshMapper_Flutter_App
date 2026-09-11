import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// The queue stamps every item with the radio configuration at enqueue
/// time, read through one getter so every producer is covered with the
/// callers untouched. No init(), so Hive stays closed and writes fall back
/// to the memory queue; extractAllAsJson() reads that back without clearing.
/// Direct assertions verify the stamp on all six factories: TX, RX,
/// successful DISC (response received), DISC drop (no response), Trace, and Defer.

void main() {
  ApiQueueService newQueue() => ApiQueueService(apiService: ApiService());

  test('every enqueue reads the radio getter at enqueue time', () async {
    final queue = newQueue();
    var tag = '910.525,62.5,7,5';
    queue.radioConfigGetter = () => tag;

    await queue.enqueueTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.25)',
      timestamp: 1757400000,
      externalAntenna: false,
    );
    await queue.enqueueRx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.25)',
      repeaterId: '4e',
      timestamp: 1757400001,
      externalAntenna: false,
    );
    await queue.enqueueDisc(
      latitude: 45.0,
      longitude: -75.0,
      repeaterId: '4e2f',
      nodeType: 'REPEATER',
      localSnr: 10.5,
      localRssi: -88,
      remoteSnr: 8.25,
      pubkeyFull: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      timestamp: 1757400002,
      externalAntenna: false,
    );
    await queue.enqueueDiscDrop(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: 1757400003,
      externalAntenna: false,
    );
    tag = '906.875,250,10,5';
    await queue.enqueueTrace(
      latitude: 45.0,
      longitude: -75.0,
      repeaterId: '4e2f',
      localSnr: 10.5,
      localRssi: -88,
      remoteSnr: 8.25,
      timestamp: 1757400004,
      externalAntenna: false,
    );
    await queue.enqueueDefer(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: 1757400005,
      held: 'tx',
    );

    final json = await queue.extractAllAsJson();
    expect(json.map((j) => j['radio_freq']), [
      '910.525,62.5,7,5',
      '910.525,62.5,7,5',
      '910.525,62.5,7,5',
      '906.875,250,10,5',
      '906.875,250,10,5',
      '910.525,62.5,7,5',
    ]);
  });

  test('no getter wired means no stamp', () async {
    final queue = newQueue();
    await queue.enqueueTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: 'None',
      timestamp: 1757400000,
      externalAntenna: false,
    );
    final json = await queue.extractAllAsJson();
    expect(json.single.containsKey('radio_freq'), isFalse);
  });

  test('a getter answering null means no stamp', () async {
    final queue = newQueue();
    queue.radioConfigGetter = () => null;
    await queue.enqueueDefer(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: 1757400000,
      held: 'disc',
    );
    final json = await queue.extractAllAsJson();
    expect(json.single.containsKey('radio_freq'), isFalse);
  });
}
