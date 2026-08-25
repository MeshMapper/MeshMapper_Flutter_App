import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/log_entry.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/services/app_intents/siri_snapshot_builder.dart';
import 'package:mesh_mapper/services/app_intents/siri_snapshot_models.dart';
import 'package:mesh_mapper/services/watch/watch_models.dart';

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(1787535920000);
  const capitolHill = Repeater(
    id: 'database-123',
    hexId: '4E5D82AA',
    name: 'Capitol Hill',
    lat: 47.6202,
    lon: -122.3194,
    lastHeard: 1787535900,
    enabled: 1,
    iata: 'SEA',
  );

  List<SiriRepeaterObservation> build({
    List<TxLogEntry> tx = const [],
    List<RxLogEntry> rx = const [],
    List<DiscLogEntry> discovery = const [],
    List<TraceLogEntry> trace = const [],
    List<Repeater> repeaters = const [capitolHill],
  }) =>
      SiriSnapshotBuilder.buildRecentHeard(
        txEntries: tx,
        rxEntries: rx,
        discoveryEntries: discovery,
        traceEntries: trace,
        repeaters: repeaters,
        zoneCode: 'SEA',
        hopBytes: 2,
        now: now,
      );

  test('direct TX resolves only an unambiguous identity and uses event GPS',
      () {
    final at = now.subtract(const Duration(minutes: 1));
    final observations = build(tx: [
      TxLogEntry(
        timestamp: at,
        latitude: 47.6000,
        longitude: -122.3000,
        power: 1,
        events: [RxEvent(repeaterId: '4E5D', snr: 8.5, rssi: -91)],
      ),
    ]);

    expect(observations, hasLength(1));
    final heard = observations.single;
    expect(heard.name, 'Capitol Hill');
    expect(heard.entityId, 'SEA|database-123');
    expect(heard.direct, isTrue);
    expect(
        heard.distanceM,
        closeTo(
          WatchWire.distanceMeters(
            47.6000,
            -122.3000,
            capitolHill.lat,
            capitolHill.lon,
          ),
          0.01,
        ));
  });

  test('ambiguous short hashes stay unnamed', () {
    const collision = Repeater(
      id: 'database-456',
      hexId: '4E5D99BB',
      name: 'Collision',
      lat: 47.7,
      lon: -122.4,
      lastHeard: 1787535900,
      enabled: 1,
      iata: 'SEA',
    );
    final observations = build(
      tx: [
        TxLogEntry(
          timestamp: now,
          latitude: 47.6,
          longitude: -122.3,
          power: 1,
          events: [RxEvent(repeaterId: '4E5D', snr: 7.2)],
        ),
      ],
      repeaters: const [capitolHill, collision],
    );

    expect(observations.single.resolved, isFalse);
    expect(observations.single.name, isNull);
    expect(observations.single.entityId, isNull);
  });

  test('multi-hop TX preserves route semantics and signal values', () {
    final observations = build(tx: [
      TxLogEntry(
        timestamp: now,
        latitude: 47.6,
        longitude: -122.3,
        power: 1,
        events: const [],
        multiHopEvents: [
          MultiHopEchoEvent(
            repeaterId: '4E5D82AA',
            snr: 3.25,
            rssi: -102,
            pathHops: const ['AA', 'BB', '4E5D82AA'],
          ),
        ],
      ),
    ]);

    final heard = observations.single;
    expect(heard.kind, SiriObservationKind.txEcho);
    expect(heard.direct, isFalse);
    expect(heard.hopCount, 3);
    expect(heard.snr, 3.25);
    expect(heard.rssi, -102);
  });

  test('passive RX preserves SNR RSSI and path count', () {
    final observations = build(rx: [
      RxLogEntry(
        timestamp: now,
        repeaterId: '4E5D82AA',
        snr: -1.5,
        rssi: -111,
        pathLength: 2,
        header: 0x01,
        latitude: 47.6,
        longitude: -122.3,
      ),
    ]);

    final heard = observations.single;
    expect(heard.kind, SiriObservationKind.passiveRx);
    expect(heard.direct, isFalse);
    expect(heard.hopCount, 2);
    expect(heard.snr, -1.5);
    expect(heard.rssi, -111);
  });

  test('discovery full pubkey disambiguates while failed trace is omitted', () {
    const collision = Repeater(
      id: 'database-456',
      hexId: '4E5D99BB',
      name: 'Collision',
      lat: 47.7,
      lon: -122.4,
      lastHeard: 1787535900,
      enabled: 1,
      iata: 'SEA',
    );
    final observations = build(
      discovery: [
        DiscLogEntry(
          timestamp: now,
          latitude: 47.6,
          longitude: -122.3,
          discoveredNodes: [
            DiscoveredNodeEntry(
              repeaterId: '4E5D',
              nodeType: 'REPEATER',
              localSnr: 6,
              localRssi: -90,
              remoteSnr: 4,
              pubkeyHex:
                  '4E5D82AA00000000000000000000000000000000000000000000000000000000',
            ),
          ],
        ),
      ],
      trace: [
        TraceLogEntry(
          timestamp: now,
          latitude: 47.6,
          longitude: -122.3,
          targetRepeaterId: '4E5D82AA',
          success: false,
        ),
      ],
      repeaters: const [capitolHill, collision],
    );

    expect(observations, hasLength(1));
    expect(observations.single.kind, SiriObservationKind.discovery);
    expect(observations.single.name, 'Capitol Hill');
  });

  test('discovery without enough identity never guesses a collision', () {
    const collision = Repeater(
      id: 'database-456',
      hexId: '4E5D99BB',
      name: 'Collision',
      lat: 47.7,
      lon: -122.4,
      lastHeard: 1787535900,
      enabled: 1,
      iata: 'SEA',
    );
    final observations = build(
      discovery: [
        DiscLogEntry(
          timestamp: now,
          latitude: 47.6,
          longitude: -122.3,
          discoveredNodes: [
            DiscoveredNodeEntry(
              repeaterId: '4E5D',
              nodeType: 'REPEATER',
              localSnr: 2,
              localRssi: -105,
              remoteSnr: 1,
            ),
          ],
        ),
      ],
      repeaters: const [capitolHill, collision],
    );

    expect(observations.single.resolved, isFalse);
    expect(observations.single.name, isNull);
  });

  test('successful trace resolves its exact target', () {
    final observations = build(trace: [
      TraceLogEntry(
        timestamp: now,
        latitude: 47.6,
        longitude: -122.3,
        targetRepeaterId: '4E5D82AA',
        localSnr: 9,
        localRssi: -88,
        success: true,
      ),
    ]);

    final heard = observations.single;
    expect(heard.kind, SiriObservationKind.trace);
    expect(heard.name, 'Capitol Hill');
    expect(heard.entityId, 'SEA|database-123');
  });

  test('duplicate observations are retained as separate events', () {
    final entries = [
      for (var index = 0; index < 2; index++)
        RxLogEntry(
          timestamp: now.subtract(Duration(seconds: index)),
          repeaterId: '4E5D82AA',
          pathLength: 1,
          header: 0,
          latitude: 47.6,
          longitude: -122.3,
        ),
    ];

    final observations = build(rx: entries);
    expect(observations, hasLength(2));
    expect(observations.map((item) => item.entityId).toSet(), hasLength(1));
  });

  test('history is newest-first, two-hour bounded, and capped at 64', () {
    final entries = List.generate(
      70,
      (index) => RxLogEntry(
        timestamp: now.subtract(Duration(minutes: index)),
        repeaterId: '4E5D82AA',
        pathLength: 1,
        header: 0,
        latitude: 47.6,
        longitude: -122.3,
      ),
    )..add(RxLogEntry(
        timestamp: now.subtract(const Duration(hours: 3)),
        repeaterId: '4E5D82AA',
        pathLength: 1,
        header: 0,
        latitude: 47.6,
        longitude: -122.3,
      ));

    final observations = build(rx: entries);

    expect(observations, hasLength(64));
    expect(observations.first.observedAt, now);
    expect(
      observations.every(
        (item) => now.difference(item.observedAt) <= const Duration(hours: 2),
      ),
      isTrue,
    );
  });

  test('non-finite radio and repeater values cannot poison the snapshot', () {
    const invalidLocation = Repeater(
      id: 'invalid-location',
      hexId: 'AABBCCDD',
      name: 'Invalid Location',
      lat: double.infinity,
      lon: -122.3,
      lastHeard: 1787535900,
      enabled: 1,
      iata: 'SEA',
    );
    final observations = build(
      rx: [
        RxLogEntry(
          timestamp: now,
          repeaterId: 'AABBCCDD',
          snr: double.nan,
          pathLength: 1,
          header: 0,
          latitude: 47.6,
          longitude: -122.3,
        ),
      ],
      repeaters: const [invalidLocation],
    );

    expect(observations.single.snr, isNull);
    expect(observations.single.distanceM, isNull);
    expect(observations.single.repeaterLat, isNull);
    expect(observations.single.repeaterLon, isNull);

    final catalog = SiriSnapshotBuilder.buildRepeaterCatalog(
      const [invalidLocation],
    );
    expect(catalog.single.latitude, isNull);
    expect(catalog.single.longitude, isNull);
  });

  test('repeater catalogue is active-first, recent-first, and bounded', () {
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final repeaters = List.generate(
      SiriSnapshotBuilder.maximumRepeaters + 10,
      (index) => Repeater(
        id: 'repeater-$index',
        hexId: index.toRadixString(16).padLeft(8, '0'),
        name: 'Repeater $index',
        lat: 47.0 + index / 1000,
        lon: -122.0,
        lastHeard: nowSeconds - index,
        enabled: 1,
        iata: 'SEA',
        staleTime: index == 7 ? nowSeconds + 3600 : nowSeconds - 1,
      ),
    );

    final catalog = SiriSnapshotBuilder.buildRepeaterCatalog(repeaters);

    expect(catalog, hasLength(SiriSnapshotBuilder.maximumRepeaters));
    expect(catalog.first.id, 'SEA|repeater-7');
    expect(catalog[1].id, 'SEA|repeater-0');
  });
}
