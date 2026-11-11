import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/api_queue_item.dart';

/// An altitude is uploaded only together with its reference, and its accuracy
/// only beside both. An item holding an altitude with no reference emits none
/// of the three keys. Contract: MeshMapper_Server/docs/APP_API.md.

const _ts = 1768762843;

Map<String, dynamic> _tx({
  double? altitude,
  String? altitudeRef,
  double? altitudeAccuracy,
}) =>
    ApiQueueItem.fromTx(
      latitude: 45.0,
      longitude: -75.0,
      heardRepeats: '4e(12.25)',
      timestamp: _ts,
      externalAntenna: false,
      altitude: altitude,
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
    ).toApiJson();

void main() {
  group('altitude trio in toApiJson', () {
    test('all three present, rounded', () {
      final j = _tx(altitude: 123.6, altitudeRef: 'msl', altitudeAccuracy: 5.4);
      expect(j['altitude'], 124);
      expect(j['altitude_ref'], 'msl');
      expect(j['altitude_acc'], 5);
    });

    test('altitude and reference without accuracy', () {
      final j = _tx(altitude: 84.0, altitudeRef: 'ellipsoid');
      expect(j['altitude'], 84);
      expect(j['altitude_ref'], 'ellipsoid');
      expect(j.containsKey('altitude_acc'), isFalse);
    });

    test('an altitude with no reference emits none of the three', () {
      final j = _tx(altitude: 84.0, altitudeAccuracy: 5.0);
      expect(j.containsKey('altitude'), isFalse);
      expect(j.containsKey('altitude_ref'), isFalse);
      expect(j.containsKey('altitude_acc'), isFalse);
    });

    test('a reference with no altitude emits none of the three', () {
      final j = _tx(altitudeRef: 'msl', altitudeAccuracy: 5.0);
      expect(j.containsKey('altitude'), isFalse);
      expect(j.containsKey('altitude_ref'), isFalse);
      expect(j.containsKey('altitude_acc'), isFalse);
    });

    test('a zero, negative, infinite or NaN accuracy is not sent', () {
      for (final acc in [0.0, -1.0, double.infinity, double.nan]) {
        final j =
            _tx(altitude: 84.0, altitudeRef: 'msl', altitudeAccuracy: acc);
        expect(j['altitude'], 84, reason: '$acc');
        expect(j.containsKey('altitude_acc'), isFalse, reason: '$acc');
      }
    });

    test('a sub-meter accuracy rounds to 0 and is still sent', () {
      final j = _tx(altitude: 84.0, altitudeRef: 'msl', altitudeAccuracy: 0.4);
      expect(j['altitude_acc'], 0);
    });

    test('nothing at all when the item has no altitude', () {
      final j = _tx();
      expect(j.containsKey('altitude'), isFalse);
      expect(j.containsKey('altitude_ref'), isFalse);
      expect(j.containsKey('altitude_acc'), isFalse);
    });

    test('RX carries the trio', () {
      final j = ApiQueueItem.fromRx(
        latitude: 45.0,
        longitude: -75.0,
        heardRepeats: '4e(12.0)',
        timestamp: _ts,
        externalAntenna: false,
        altitude: 80.2,
        altitudeRef: 'msl',
        altitudeAccuracy: 3.0,
      ).toApiJson();
      expect(j['altitude'], 80);
      expect(j['altitude_ref'], 'msl');
      expect(j['altitude_acc'], 3);
    });

    test('DISC carries the trio', () {
      final pubkey = 'ab' * 32;
      final j = ApiQueueItem.fromDisc(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: '4e',
        nodeType: 'repeater',
        localSnr: 10.0,
        localRssi: -90,
        remoteSnr: 8.0,
        pubkeyFull: pubkey,
        timestamp: _ts,
        externalAntenna: false,
        altitude: 200.0,
        altitudeRef: 'ellipsoid',
        altitudeAccuracy: 12.0,
      ).toApiJson();
      expect(j['altitude'], 200);
      expect(j['altitude_ref'], 'ellipsoid');
      expect(j['altitude_acc'], 12);
    });

    test('DISC drop carries the trio', () {
      final j = ApiQueueItem.fromDiscDrop(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: _ts,
        externalAntenna: false,
        altitude: 200.0,
        altitudeRef: 'msl',
        altitudeAccuracy: 2.0,
      ).toApiJson();
      expect(j['altitude'], 200);
      expect(j['altitude_ref'], 'msl');
      expect(j['altitude_acc'], 2);
    });

    test('TRACE carries the trio', () {
      final j = ApiQueueItem.fromTrace(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: '4e',
        localSnr: 10.0,
        localRssi: -90,
        remoteSnr: 8.0,
        timestamp: _ts,
        externalAntenna: false,
        altitude: -3.4,
        altitudeRef: 'msl',
        altitudeAccuracy: 7.6,
      ).toApiJson();
      expect(j['altitude'], -3);
      expect(j['altitude_ref'], 'msl');
      expect(j['altitude_acc'], 8);
    });

    test('TRACE with an unlabelled altitude emits none of the three', () {
      final j = ApiQueueItem.fromTrace(
        latitude: 45.0,
        longitude: -75.0,
        repeaterId: '4e',
        localSnr: 10.0,
        localRssi: -90,
        remoteSnr: 8.0,
        timestamp: _ts,
        externalAntenna: false,
        altitude: 50.0,
      ).toApiJson();
      expect(j.containsKey('altitude'), isFalse);
      expect(j.containsKey('altitude_ref'), isFalse);
    });

    test('DEFER and SCOPES never carry any of the three', () {
      final defer = ApiQueueItem.fromDefer(
        latitude: 45.0,
        longitude: -75.0,
        timestamp: _ts,
        held: 'tx',
      ).toApiJson();
      final scopes = ApiQueueItem.fromScopes(
        publicKeyHex:
            'A3B2C1D4E5F6A7B8C9D0E1F2A3B4C5D6E7F8A9B0C1D2E3F4A5B6C7D8E9F0A1B2',
        scopes: const ['ROOM1'],
        lat: 45.0,
        lon: -75.0,
        timestamp: _ts,
      ).toApiJson();
      for (final j in [defer, scopes]) {
        expect(j.containsKey('altitude'), isFalse);
        expect(j.containsKey('altitude_ref'), isFalse);
        expect(j.containsKey('altitude_acc'), isFalse);
      }
    });
  });
}
