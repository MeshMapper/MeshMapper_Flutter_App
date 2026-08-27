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

  SiriRecentHeard buildHeard({
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

  List<SiriRepeaterObservation> build({
    List<TxLogEntry> tx = const [],
    List<RxLogEntry> rx = const [],
    List<DiscLogEntry> discovery = const [],
    List<TraceLogEntry> trace = const [],
    List<Repeater> repeaters = const [capitolHill],
  }) =>
      buildHeard(
        tx: tx,
        rx: rx,
        discovery: discovery,
        trace: trace,
        repeaters: repeaters,
      ).observations;

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

  test('the unique count sees repeaters older than the 64 newest events', () {
    // 80 distinct repeaters, each heard once, newest first. The wire list keeps
    // the 64 newest; the count has to answer for the whole session, so the 16
    // that fall off the end must still be credited.
    final repeaters = List.generate(
      80,
      (index) => Repeater(
        id: 'database-$index',
        hexId: (0x10000000 + index).toRadixString(16).toUpperCase(),
        name: 'Repeater $index',
        lat: 47.6,
        lon: -122.3,
        lastHeard: 1787535900,
        enabled: 1,
        iata: 'SEA',
      ),
    );
    final entries = [
      for (var index = 0; index < repeaters.length; index++)
        RxLogEntry(
          timestamp: now.subtract(Duration(seconds: index)),
          repeaterId: repeaters[index].hexId,
          pathLength: 1,
          header: 0,
          latitude: 47.6,
          longitude: -122.3,
        ),
    ];

    final heard = buildHeard(rx: entries, repeaters: repeaters);

    expect(heard.observations, hasLength(64));
    expect(
      SiriSnapshotBuilder.countUniqueRepeatersHeard(
        heard.observations,
        now.subtract(const Duration(minutes: 5)),
      ),
      64,
      reason: 'the capped wire list is exactly what used to be counted',
    );
    expect(
      SiriSnapshotBuilder.countUniqueRepeatersHeard(
        heard.distinctHeard,
        now.subtract(const Duration(minutes: 5)),
      ),
      80,
    );
  });

  test('a repeater heard only outside the session is not counted', () {
    final entries = [
      RxLogEntry(
        timestamp: now.subtract(const Duration(minutes: 90)),
        repeaterId: '4E5D82AA',
        pathLength: 1,
        header: 0,
        latitude: 47.6,
        longitude: -122.3,
      ),
    ];

    final heard = buildHeard(rx: entries);

    expect(heard.distinctHeard, hasLength(1));
    expect(
      SiriSnapshotBuilder.countUniqueRepeatersHeard(
        heard.distinctHeard,
        now.subtract(const Duration(minutes: 5)),
      ),
      0,
    );
  });

  test('a repeater with no IATA keys the same on both sides of the join', () {
    const zoneless = Repeater(
      id: 'database-999',
      hexId: '77889900',
      name: 'Zoneless',
      lat: 47.6,
      lon: -122.3,
      lastHeard: 1787535900,
      enabled: 1,
    );
    final heard = buildHeard(
      rx: [
        RxLogEntry(
          timestamp: now,
          repeaterId: '77889900',
          pathLength: 1,
          header: 0,
          latitude: 47.6,
          longitude: -122.3,
        ),
      ],
      repeaters: const [zoneless],
    );
    final catalog = SiriSnapshotBuilder.buildRepeaterCatalog(
      const [zoneless],
      zoneCode: 'SEA',
    );

    expect(heard.observations.single.entityId, 'SEA|database-999');
    expect(catalog.single.id, heard.observations.single.entityId);
  });

  test('a repeater with no IATA and no zone falls back to GLOBAL', () {
    const zoneless = Repeater(
      id: 'database-999',
      hexId: '77889900',
      name: 'Zoneless',
      lat: 47.6,
      lon: -122.3,
      lastHeard: 1787535900,
      enabled: 1,
    );

    expect(
      SiriSnapshotBuilder.repeaterEntityId(zoneless, null),
      'GLOBAL|database-999',
    );
    expect(
      SiriSnapshotBuilder.buildRepeaterCatalog(const [zoneless]).single.id,
      'GLOBAL|database-999',
    );
  });

  group('unique repeaters heard is scoped to the running session', () {
    SiriRepeaterObservation heard(String hexId, Duration ago) =>
        SiriRepeaterObservation(
          entityId: 'SEA|$hexId',
          displayHexId: hexId,
          observedAt: now.subtract(ago),
          kind: SiriObservationKind.passiveRx,
          direct: true,
          hopCount: 1,
          resolved: true,
        );

    test('a previous session\'s repeaters are not credited to this one', () {
      final observations = [
        heard('AAAA1111', const Duration(minutes: 2)),
        heard('BBBB2222', const Duration(minutes: 90)),
        heard('CCCC3333', const Duration(minutes: 100)),
      ];

      expect(
        SiriSnapshotBuilder.countUniqueRepeatersHeard(
          observations,
          now.subtract(const Duration(minutes: 5)),
        ),
        1,
      );
    });

    test('an observation made at the boundary belongs to the session', () {
      // The session's own first discovery is sent and recorded before the
      // boundary is stored, so the boundary has to be inclusive and has to be
      // captured before that transmission; otherwise a fresh Passive session
      // reports nothing for its opening event.
      final startedAt = now.subtract(const Duration(minutes: 5));
      final observations = [
        SiriRepeaterObservation(
          entityId: 'SEA|first',
          displayHexId: 'AAAA1111',
          observedAt: startedAt,
          kind: SiriObservationKind.discovery,
          direct: true,
          hopCount: 1,
          resolved: true,
        ),
      ];

      expect(
        SiriSnapshotBuilder.countUniqueRepeatersHeard(observations, startedAt),
        1,
      );
    });

    test('an observation one millisecond earlier is a previous session', () {
      final startedAt = now.subtract(const Duration(minutes: 5));
      final observations = [
        SiriRepeaterObservation(
          entityId: 'SEA|earlier',
          displayHexId: 'BBBB2222',
          observedAt: startedAt.subtract(const Duration(milliseconds: 1)),
          kind: SiriObservationKind.discovery,
          direct: true,
          hopCount: 1,
          resolved: true,
        ),
      ];

      expect(
        SiriSnapshotBuilder.countUniqueRepeatersHeard(observations, startedAt),
        0,
      );
    });

    test('a session that has heard nothing yet reports zero', () {
      final observations = [heard('BBBB2222', const Duration(minutes: 90))];

      expect(
        SiriSnapshotBuilder.countUniqueRepeatersHeard(
          observations,
          now.subtract(const Duration(seconds: 10)),
        ),
        0,
      );
    });

    test('no running session means nothing to count', () {
      expect(
        SiriSnapshotBuilder.countUniqueRepeatersHeard(
          [heard('AAAA1111', const Duration(minutes: 2))],
          null,
        ),
        0,
      );
    });

    test('one repeater heard repeatedly still counts once', () {
      final observations = [
        heard('AAAA1111', const Duration(minutes: 1)),
        heard('AAAA1111', const Duration(minutes: 2)),
        heard('AAAA1111', const Duration(minutes: 3)),
      ];

      expect(
        SiriSnapshotBuilder.countUniqueRepeatersHeard(
          observations,
          now.subtract(const Duration(minutes: 10)),
        ),
        1,
      );
    });

    test('unresolved observations count by hex, not collapsed together', () {
      final observations = [
        SiriRepeaterObservation(
          displayHexId: 'DDDD4444',
          observedAt: now,
          kind: SiriObservationKind.passiveRx,
          direct: true,
          hopCount: 1,
          resolved: false,
        ),
        SiriRepeaterObservation(
          displayHexId: 'EEEE5555',
          observedAt: now,
          kind: SiriObservationKind.passiveRx,
          direct: true,
          hopCount: 1,
          resolved: false,
        ),
      ];

      expect(
        SiriSnapshotBuilder.countUniqueRepeatersHeard(
          observations,
          now.subtract(const Duration(minutes: 1)),
        ),
        2,
      );
    });
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
