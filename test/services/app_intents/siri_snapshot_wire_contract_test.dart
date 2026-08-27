import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/app_intents/siri_snapshot_models.dart';

void main() {
  test('Dart snapshot keys match the Swift Codable mirror exactly', () {
    final at = DateTime.fromMillisecondsSinceEpoch(1787535920000);
    final snapshot = SiriSnapshot(
      updatedAt: at,
      connection: const SiriConnectionSnapshot(
        isConnected: true,
        deviceName: 'MrAlders0n',
        batteryPercent: 76,
        gpsStatus: 'locked',
      ),
      session: SiriSessionSnapshot(
        id: 'session-1',
        startedAt: at.subtract(const Duration(minutes: 4)),
        active: true,
        starting: false,
        mode: 'hybrid',
        phase: 'listening',
        phaseTitle: 'Listening',
        phaseDetail: 'Waiting for echoes',
        phaseEndsAt: at,
        zoneCode: 'SEA',
        txCount: 12,
        rxCount: 8,
        discoveryCount: 4,
        traceCount: 0,
        queueSize: 0,
        uniqueRepeatersHeard: 9,
      ),
      controls: SiriControlsSnapshot(
        availableStartModes: const ['passive', 'active', 'hybrid'],
        canStart: false,
        startBlockedReason: 'Already running',
        canStop: true,
        canManualPing: false,
        manualPingBlockedReason: 'Cooling down',
        manualCooldownEndsAt: at,
      ),
      recentHeard: [
        SiriRepeaterObservation(
          entityId: 'SEA|database-123',
          displayHexId: '4E5D',
          name: 'Capitol Hill',
          observedAt: at,
          kind: SiriObservationKind.txEcho,
          direct: true,
          hopCount: 1,
          snr: 8.5,
          rssi: -91,
          distanceM: 2149.3,
          repeaterLat: 47.6202,
          repeaterLon: -122.3194,
          resolved: true,
        ),
      ],
      repeaters: [
        SiriRepeaterEntitySnapshot(
          id: 'SEA|database-123',
          name: 'Capitol Hill',
          hexId: '4E5D82AA',
          zoneCode: 'SEA',
          isActive: true,
          isNew: false,
          serverLastHeard: at,
          latitude: 47.6202,
          longitude: -122.3194,
        ),
      ],
    ).toMap();

    expect(snapshot.keys.toSet(), {
      'version',
      'updatedAtMs',
      'connection',
      'session',
      'controls',
      'recentHeard',
      'repeaters',
    });
    expect((snapshot['connection']! as Map).keys.toSet(), {
      'isConnected',
      'deviceName',
      'batteryPercent',
      'gpsStatus',
    });
    expect((snapshot['session']! as Map).keys.toSet(), {
      'id',
      'startedAtMs',
      'active',
      'starting',
      'mode',
      'phase',
      'phaseTitle',
      'phaseDetail',
      'phaseEndsAtMs',
      'zoneCode',
      'txCount',
      'rxCount',
      'discoveryCount',
      'traceCount',
      'queueSize',
      'uniqueRepeatersHeard',
    });
    expect((snapshot['controls']! as Map).keys.toSet(), {
      'availableStartModes',
      'canStart',
      'startBlockedReason',
      'canStop',
      'canManualPing',
      'manualPingBlockedReason',
      'manualCooldownEndsAtMs',
    });
    expect(((snapshot['recentHeard']! as List).single as Map).keys.toSet(), {
      'entityId',
      'displayHexId',
      'name',
      'observedAtMs',
      'kind',
      'direct',
      'hopCount',
      'snr',
      'rssi',
      'distanceM',
      'repeaterLat',
      'repeaterLon',
      'resolved',
    });
    expect(((snapshot['repeaters']! as List).single as Map).keys.toSet(), {
      'id',
      'name',
      'hexId',
      'zoneCode',
      'isActive',
      'isNew',
      'serverLastHeardMs',
      'latitude',
      'longitude',
    });

    final encoded = snapshot.toString();
    expect(encoded, isNot(contains('currentUserLatitude')));
    expect(encoded, isNot(contains('observationUserLatitude')));
    expect(encoded, isNot(contains('observationUserLongitude')));
  });
}
