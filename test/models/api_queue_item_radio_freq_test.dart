import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/api_queue_item.dart';

/// Every queued item carries the radio configuration it was recorded under,
/// the full `freqMHz,bwKHz,SF,CR` tag, so the server reads it off the row
/// instead of joining the session. A DEFER carries it too (unlike the mode
/// stamp, which a deferral never has). Unstamped items emit nothing, byte
/// for byte what they emitted before.

const _ts = 1757400000;
const _tag = '910.525,62.5,7,5';

void main() {
  test('TX carries the tag', () {
    final item = ApiQueueItem.fromTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.25)',
      timestamp: _ts,
      externalAntenna: false,
      radioFreq: _tag,
    );
    expect(item.radioFreq, _tag);
    expect(item.toApiJson()['radio_freq'], _tag);
  });

  test('RX carries the tag', () {
    final item = ApiQueueItem.fromRx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.0)',
      timestamp: _ts,
      externalAntenna: false,
      radioFreq: _tag,
    );
    expect(item.toApiJson()['radio_freq'], _tag);
  });

  test('DISC carries the tag', () {
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
      radioFreq: _tag,
    );
    expect(item.toApiJson()['radio_freq'], _tag);
  });

  test('a failed DISC carries the tag', () {
    final item = ApiQueueItem.fromDiscDrop(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: _ts,
      externalAntenna: false,
      radioFreq: _tag,
    );
    expect(item.toApiJson()['radio_freq'], _tag);
  });

  test('TRACE carries the tag', () {
    final item = ApiQueueItem.fromTrace(
      latitude: 45.0,
      longitude: -75.0,
      repeaterId: '4e2f',
      localSnr: 10.5,
      localRssi: -88,
      remoteSnr: 8.25,
      timestamp: _ts,
      externalAntenna: false,
      radioFreq: _tag,
    );
    expect(item.toApiJson()['radio_freq'], _tag);
  });

  test('DEFER carries the tag and nothing else new', () {
    final item = ApiQueueItem.fromDefer(
      latitude: 45.26974,
      longitude: -75.77746,
      timestamp: _ts,
      held: 'tx',
      radioFreq: _tag,
    );
    expect(item.toApiJson(), {
      'type': 'DEFER',
      'lat': 45.26974,
      'lon': -75.77746,
      'timestamp': _ts,
      'held': 'tx',
      'radio_freq': _tag,
    });
  });

  test('an unstamped item emits no radio_freq', () {
    final tx = ApiQueueItem.fromTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: 'None',
      timestamp: _ts,
      externalAntenna: true,
    );
    expect(tx.radioFreq, isNull);
    expect(tx.toApiJson().containsKey('radio_freq'), isFalse);
    final defer = ApiQueueItem.fromDefer(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: _ts,
      held: 'disc',
    );
    expect(defer.toApiJson().containsKey('radio_freq'), isFalse);
  });
}
