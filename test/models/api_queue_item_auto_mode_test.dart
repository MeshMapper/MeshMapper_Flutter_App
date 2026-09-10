import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/api_queue_item.dart';

/// Every queued item may carry the auto mode that produced it, and a DEFER
/// item reports a square where smart pinging held a ping. When no mode is
/// stamped, the JSON is byte for byte what it was before.

const _ts = 1757400000;

void main() {
  group('auto_mode stamp', () {
    test('TX carries the stamp', () {
      final item = ApiQueueItem.fromTx(
        latitude: 45.0,
        longitude: -75.0,
        heardRepeats: '4e(12.25)',
        timestamp: _ts,
        externalAntenna: false,
        autoMode: 'active',
      );
      expect(item.autoMode, 'active');
      expect(item.toApiJson()['auto_mode'], 'active');
    });

    test('RX carries the stamp', () {
      final item = ApiQueueItem.fromRx(
        latitude: 45.0,
        longitude: -75.0,
        heardRepeats: '4e(12.0)',
        timestamp: _ts,
        externalAntenna: false,
        autoMode: 'passive',
      );
      expect(item.toApiJson()['auto_mode'], 'passive');
    });

    test('DISC carries the stamp', () {
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
        autoMode: 'hybrid',
      );
      expect(item.toApiJson()['auto_mode'], 'hybrid');
    });

    test('a failed DISC carries the stamp', () {
      final item = ApiQueueItem.fromDiscDrop(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: _ts,
        externalAntenna: false,
        autoMode: 'passive',
      );
      expect(item.toApiJson()['repeater_id'], 'None');
      expect(item.toApiJson()['auto_mode'], 'passive');
    });

    test('TRACE carries the stamp', () {
      final item = ApiQueueItem.fromTrace(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: '4e2f',
        localSnr: 10.5,
        localRssi: -88,
        remoteSnr: 8.25,
        timestamp: _ts,
        externalAntenna: false,
        autoMode: 'trace',
      );
      expect(item.toApiJson()['auto_mode'], 'trace');
    });

    test('unstamped JSON is exactly what it was', () {
      final tx = ApiQueueItem.fromTx(
        latitude: 45.0,
        longitude: -75.0,
        heardRepeats: '4e(12.25)',
        timestamp: _ts,
        externalAntenna: true,
        noiseFloor: -104,
        power: 0.3,
      );
      expect(tx.autoMode, isNull);
      expect(tx.toApiJson(), {
        'type': 'TX',
        'lat': 45.0,
        'lon': -75.0,
        'noisefloor': -104,
        'heard_repeats': '4e(12.25)',
        'timestamp': _ts,
        'external_antenna': true,
        'power': '0.3w',
      });

      final trace = ApiQueueItem.fromTrace(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: '4e2f',
        localSnr: 10.5,
        localRssi: -88,
        remoteSnr: 8.25,
        timestamp: _ts,
        externalAntenna: false,
      );
      expect(trace.toApiJson().containsKey('auto_mode'), isFalse);

      final disc = ApiQueueItem.fromDiscDrop(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: _ts,
        externalAntenna: false,
      );
      expect(disc.toApiJson().containsKey('auto_mode'), isFalse);
    });
  });

  group('DEFER item', () {
    test('carries exactly type, lat, lon, timestamp and held', () {
      final item = ApiQueueItem.fromDefer(
        latitude: 45.26974,
        longitude: -75.77746,
        timestamp: _ts,
        held: 'tx',
      );
      expect(item.type, 'DEFER');
      expect(item.externalAntenna, isFalse);
      expect(item.hasWireTag, isFalse);
      expect(item.toApiJson(), {
        'type': 'DEFER',
        'lat': 45.26974,
        'lon': -75.77746,
        'timestamp': _ts,
        'held': 'tx',
      });
    });

    test('a discovery hold is held disc', () {
      final item = ApiQueueItem.fromDefer(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: _ts,
        held: 'disc',
      );
      expect(item.toApiJson()['held'], 'disc');
    });

    test('never carries the mode stamp', () {
      final item = ApiQueueItem.fromDefer(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: _ts,
        held: 'tx',
      );
      expect(item.autoMode, isNull);
      expect(item.toApiJson(), {
        'type': 'DEFER',
        'lat': 45.0,
        'lon': -75.0,
        'timestamp': _ts,
        'held': 'tx',
      });
    });
  });
}
