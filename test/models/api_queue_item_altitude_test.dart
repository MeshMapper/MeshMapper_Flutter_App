import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/api_queue_item.dart';

/// Every wardrive post carries the phone's altitude in whole meters, and
/// leaves the key out entirely when the phone did not know it.

const _ts = 1768762843;

void main() {
  group('altitude in toApiJson', () {
    test('TX carries a rounded altitude', () {
      final item = ApiQueueItem.fromTx(
        latitude: 45.0,
        longitude: -75.0,
        heardRepeats: '4e(12.25)',
        timestamp: _ts,
        externalAntenna: false,
        altitude: 123.6,
      );
      expect(item.toApiJson()['altitude'], 124);
    });

    test('TX omits the key when altitude is unknown', () {
      final item = ApiQueueItem.fromTx(
        latitude: 45.0,
        longitude: -75.0,
        heardRepeats: 'None',
        timestamp: _ts,
        externalAntenna: false,
      );
      expect(item.toApiJson().containsKey('altitude'), isFalse);
    });

    test('RX carries altitude', () {
      final item = ApiQueueItem.fromRx(
        latitude: 45.0,
        longitude: -75.0,
        heardRepeats: '4e(12.0)',
        timestamp: _ts,
        externalAntenna: false,
        altitude: 80.2,
      );
      expect(item.toApiJson()['altitude'], 80);
    });

    test('DISC carries altitude', () {
      final item = ApiQueueItem.fromDisc(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: '4e',
        nodeType: 'repeater',
        localSnr: 10.0,
        localRssi: -90,
        remoteSnr: 8.0,
        pubkeyFull: 'ab' * 32,
        timestamp: _ts,
        externalAntenna: false,
        altitude: 200.0,
      );
      expect(item.toApiJson()['altitude'], 200);
    });

    test('DISC drop carries altitude', () {
      final item = ApiQueueItem.fromDiscDrop(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: _ts,
        externalAntenna: false,
        altitude: 200.0,
      );
      expect(item.toApiJson()['altitude'], 200);
    });

    test('TRACE carries altitude', () {
      final item = ApiQueueItem.fromTrace(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: '4e',
        localSnr: 10.0,
        localRssi: -90,
        remoteSnr: 8.0,
        timestamp: _ts,
        externalAntenna: false,
        altitude: -3.4,
      );
      expect(item.toApiJson()['altitude'], -3);
    });

    test('TRACE omits the key when altitude is unknown', () {
      final item = ApiQueueItem.fromTrace(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: '4e',
        localSnr: 10.0,
        localRssi: -90,
        remoteSnr: 8.0,
        timestamp: _ts,
        externalAntenna: false,
      );
      expect(item.toApiJson().containsKey('altitude'), isFalse);
    });
  });
}
