import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/api_queue_service.dart';
import 'package:mesh_mapper/services/api_service.dart';

/// Every enqueue method passes the altitude trio through to the item it
/// builds. Offline mode is used because its rows are the item's own JSON,
/// held in memory with no Hive box to open.
void main() {
  const ts = 1768762843;
  final pubkey = 'ab' * 32;

  ApiQueueService queue() =>
      ApiQueueService(apiService: ApiService())..offlineMode = true;

  void expectTrio(Map<String, dynamic> row, String ref, int acc) {
    expect(row['altitude'], 84);
    expect(row['altitude_ref'], ref);
    expect(row['altitude_acc'], acc);
  }

  test('enqueueTx', () async {
    final q = queue();
    await q.enqueueTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.25)',
      timestamp: ts,
      externalAntenna: false,
      altitude: 84.0,
      altitudeRef: 'msl',
      altitudeAccuracy: 6.0,
    );
    expectTrio(q.getOfflinePingsSnapshot().single, 'msl', 6);
  });

  test('enqueueRx', () async {
    final q = queue();
    await q.enqueueRx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.0)',
      timestamp: ts,
      repeaterId: '4e',
      externalAntenna: false,
      altitude: 84.0,
      altitudeRef: 'ellipsoid',
      altitudeAccuracy: 9.0,
    );
    expectTrio(q.getOfflinePingsSnapshot().single, 'ellipsoid', 9);
  });

  test('enqueueDisc', () async {
    final q = queue();
    await q.enqueueDisc(
      latitude: 45.0,
      longitude: -75.0,
      repeaterId: '4e',
      nodeType: 'repeater',
      localSnr: 10.0,
      localRssi: -90,
      remoteSnr: 8.0,
      pubkeyFull: pubkey,
      timestamp: ts,
      externalAntenna: false,
      altitude: 84.0,
      altitudeRef: 'msl',
      altitudeAccuracy: 3.0,
    );
    expectTrio(q.getOfflinePingsSnapshot().single, 'msl', 3);
  });

  test('enqueueDiscDrop', () async {
    final q = queue();
    await q.enqueueDiscDrop(
      latitude: 45.0,
      longitude: -75.0,
      timestamp: ts,
      externalAntenna: false,
      altitude: 84.0,
      altitudeRef: 'msl',
      altitudeAccuracy: 2.0,
    );
    expectTrio(q.getOfflinePingsSnapshot().single, 'msl', 2);
  });

  test('enqueueTrace', () async {
    final q = queue();
    await q.enqueueTrace(
      latitude: 45.0,
      longitude: -75.0,
      repeaterId: '4e',
      localSnr: 10.0,
      localRssi: -90,
      remoteSnr: 8.0,
      timestamp: ts,
      externalAntenna: false,
      altitude: 84.0,
      altitudeRef: 'ellipsoid',
      altitudeAccuracy: 7.0,
    );
    expectTrio(q.getOfflinePingsSnapshot().single, 'ellipsoid', 7);
  });

  test('an unlabelled altitude leaves no altitude on the row', () async {
    final q = queue();
    await q.enqueueTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: 'None',
      timestamp: ts,
      externalAntenna: false,
      altitude: 84.0,
    );
    final row = q.getOfflinePingsSnapshot().single;
    expect(row.containsKey('altitude'), isFalse);
    expect(row.containsKey('altitude_ref'), isFalse);
  });

  test('altitudeLabelSummary counts labelled rows by type, skipping DEFER', () {
    expect(
        altitudeLabelSummary([
          {'type': 'TX', 'altitude_ref': 'msl'},
          {'type': 'TX'},
          {'type': 'RX', 'altitude_ref': 'ellipsoid'},
          {'type': 'DEFER'},
        ]),
        'altitude_ref 2/3 (TX 1/2, RX 1/1)');
    expect(altitudeLabelSummary(const []), 'altitude_ref 0/0');
  });
}
