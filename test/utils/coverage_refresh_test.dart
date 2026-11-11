import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/api_queue_item.dart';
import 'package:mesh_mapper/utils/coverage_refresh.dart';

/// After an upload the app asks the region server to re-render the tiles the
/// batch touched. DEFER and SCOPES change no tile, so a batch of nothing but
/// those arms no refresh and contributes no coordinates.
void main() {
  const key = 'A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2';

  ApiQueueItem disc(double lat) => ApiQueueItem.fromDisc(
        latitude: lat,
        longitude: -75.0,
        repeaterId: 'A3',
        nodeType: 'REPEATER',
        localSnr: 1,
        localRssi: -90,
        remoteSnr: 1,
        pubkeyFull: key,
        timestamp: 1757400000,
        externalAntenna: false,
      );
  ApiQueueItem scopes(double lat) => ApiQueueItem.fromScopes(
      publicKeyHex: key, scopes: ['*'], lat: lat, lon: -75.0,
      timestamp: 1757400001);
  ApiQueueItem defer(double lat) => ApiQueueItem.fromDefer(
      latitude: lat, longitude: -75.0, timestamp: 1757400002, held: 'disc');

  test('DEFER and SCOPES change no coverage, everything else does', () {
    expect(changesCoverage('DEFER'), isFalse);
    expect(changesCoverage('SCOPES'), isFalse);
    for (final t in ['TX', 'RX', 'DISC', 'TRACE', 'DISC_DROP']) {
      expect(changesCoverage(t), isTrue, reason: t);
    }
  });

  test('a SCOPES-only batch arms nothing and adds no coordinates', () {
    final r = coverageRefreshFor([scopes(45.1), scopes(45.2)],
        alreadyPending: 0);
    expect(r.armsRefresh, isFalse);
    expect(r.coords, isEmpty);
  });

  test('a DISC beside its SCOPES and a DEFER contributes only its own fix',
      () {
    final r = coverageRefreshFor([disc(45.1), scopes(45.2), defer(45.3)],
        alreadyPending: 0);
    expect(r.armsRefresh, isTrue);
    expect(r.coords, [
      [45.1, -75.0]
    ]);
  });

  test('coordinates stop at the cap, counting what is already pending', () {
    final r = coverageRefreshFor(
        [for (var i = 0; i < 10; i++) disc(45.0 + i / 100)],
        alreadyPending: 14);
    expect(r.armsRefresh, isTrue);
    expect(r.coords, hasLength(2));
  });
}
