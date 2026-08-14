import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/log_entry.dart';
import 'package:mesh_mapper/models/ping_data.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart'
    show OverlayPingType;
import 'package:mesh_mapper/services/watch/watch_geo_builder.dart';
import 'package:mesh_mapper/services/watch/watch_models.dart';
import 'package:mesh_mapper/utils/ping_colors.dart';

TxPing _tx(DateTime at, {List<HeardRepeater> heard = const []}) => TxPing(
      latitude: 47.6,
      longitude: -122.3,
      power: 22,
      timestamp: at,
      deviceId: 'dev',
      heardRepeaters: List.of(heard),
    );

RxPing _rx(DateTime at) => RxPing(
      latitude: 47.61,
      longitude: -122.31,
      repeaterId: '4e',
      timestamp: at,
      snr: 5.0,
      rssi: -90,
    );

DiscLogEntry _disc(DateTime at, {required bool discovered}) => DiscLogEntry(
      timestamp: at,
      latitude: 47.62,
      longitude: -122.32,
      discoveredNodes: discovered
          ? [
              DiscoveredNodeEntry(
                repeaterId: '7a',
                nodeType: 'REPEATER',
                localSnr: 7,
                localRssi: -88,
                remoteSnr: 5,
              ),
            ]
          : [],
    );

TraceLogEntry _trace(DateTime at, {required bool success}) => TraceLogEntry(
      timestamp: at,
      latitude: 47.63,
      longitude: -122.33,
      targetRepeaterId: '8b',
      success: success,
    );

Repeater _repeater({
  required String id,
  required double lat,
  required double lon,
  String name = 'Rep',
  String hexId = '',
  int? createdAt,
  int? staleTime,
}) =>
    Repeater(
      id: id,
      hexId: hexId,
      name: name,
      lat: lat,
      lon: lon,
      lastHeard: DateTime.now().millisecondsSinceEpoch ~/ 1000,
      enabled: 1,
      createdAt: createdAt,
      staleTime: staleTime,
    );

void main() {
  setUp(() => PingColors.setColorVisionType(ColorVisionType.none));

  group('buildPings', () {
    test('marker identity survives a new event arriving at the front', () {
      // These histories insert newest-first. A positional id renumbered every
      // surviving marker whenever one arrived, so SwiftUI rebuilt all sixty
      // annotations to show one new dot.
      final base = DateTime(2026, 8, 12, 10);
      final older = List.generate(5, (i) => _disc(base.add(Duration(minutes: i)), discovered: true));

      List<String> idsFor(List<DiscLogEntry> entries) => WatchGeoBuilder.buildPings(
            txPings: const [],
            rxPings: const [],
            discLogEntries: entries,
            traceLogEntries: const [],
          ).map((p) => p.id).toList();

      final before = idsFor(older.reversed.toList());
      final arrival = _disc(base.add(const Duration(minutes: 9)), discovered: true);
      final after = idsFor([arrival, ...older.reversed]);

      expect(after.length, before.length + 1);
      expect(
        after.toSet().containsAll(before),
        isTrue,
        reason: 'every pre-existing marker must keep its id',
      );
    });

    test('two events of one kind in the same millisecond stay distinct', () {
      final at = DateTime(2026, 8, 12, 10);
      final pings = WatchGeoBuilder.buildPings(
        txPings: const [],
        rxPings: const [],
        discLogEntries: [_disc(at, discovered: true), _disc(at, discovered: false)],
        traceLogEntries: const [],
      );
      expect(pings.map((p) => p.id).toSet().length, 2);
    });

    test('merges TX and RX newest-first and caps the list', () {
      final base = DateTime(2026, 8, 12, 10);
      final tx = List.generate(40, (i) => _tx(base.add(Duration(minutes: i))));
      final rx = List.generate(40, (i) => _rx(base.add(Duration(seconds: i))));

      final pings = WatchGeoBuilder.buildPings(
        txPings: tx,
        rxPings: rx,
        discLogEntries: const [],
        traceLogEntries: const [],
      );

      expect(pings.length, WatchWire.maxPings);
      for (var i = 1; i < pings.length; i++) {
        expect(
          pings[i - 1].at.isAfter(pings[i].at) ||
              pings[i - 1].at.isAtSameMomentAs(pings[i].at),
          isTrue,
          reason: 'pings must be newest-first',
        );
      }
    });

    test('an unanswered TX is coloured as a failure', () {
      final answered = _tx(
        DateTime(2026, 8, 12, 10, 1),
        heard: const [HeardRepeater(repeaterId: '4e', snr: 6)],
      );
      final ignored = _tx(DateTime(2026, 8, 12, 10));

      final pings = WatchGeoBuilder.buildPings(
        txPings: [answered, ignored],
        rxPings: const [],
        discLogEntries: const [],
        traceLogEntries: const [],
      );

      final byTime = {for (final p in pings) p.at: p};
      expect(
        byTime[answered.timestamp]!.color,
        WatchColor.fromColor(PingColors.txSuccess),
      );
      expect(
        byTime[ignored.timestamp]!.color,
        WatchColor.fromColor(PingColors.txFail),
      );
    });

    test('multi-hop-only TX is RX-coloured unless any echo is direct', () {
      final multiHopOnly = _tx(
        DateTime(2026, 8, 12, 10, 2),
        heard: const [
          HeardRepeater(
            repeaterId: '4e',
            snr: 6,
            pathHops: ['7a', '4e'],
          ),
          HeardRepeater(
            repeaterId: '5f',
            snr: 3,
            pathHops: ['8b', '5f'],
          ),
        ],
      );
      final includesDirect = _tx(
        DateTime(2026, 8, 12, 10, 1),
        heard: const [
          HeardRepeater(
            repeaterId: '4e',
            snr: 6,
            pathHops: ['7a', '4e'],
          ),
          HeardRepeater(repeaterId: '5f', snr: 3),
        ],
      );

      final pings = WatchGeoBuilder.buildPings(
        txPings: [multiHopOnly, includesDirect],
        rxPings: const [],
        discLogEntries: const [],
        traceLogEntries: const [],
      );

      final byTime = {for (final ping in pings) ping.at: ping};
      expect(byTime[multiHopOnly.timestamp]!.kind, 'tx');
      expect(
        byTime[multiHopOnly.timestamp]!.color,
        WatchColor.fromColor(PingColors.rx),
      );
      expect(
        byTime[includesDirect.timestamp]!.color,
        WatchColor.fromColor(PingColors.txSuccess),
      );
    });

    test('outcome colour follows the newest event across every history', () {
      final base = DateTime(2026, 8, 12, 10);
      final tx = _tx(
        base,
        heard: const [HeardRepeater(repeaterId: '4e', snr: 6)],
      );
      final discovery = _disc(
        base.add(const Duration(seconds: 1)),
        discovered: true,
      );
      final trace = _trace(
        base.add(const Duration(seconds: 2)),
        success: false,
      );
      final rx = _rx(base.add(const Duration(seconds: 3)));

      WatchColor? latest({
        List<RxPing> rxPings = const [],
        List<TraceLogEntry> traces = const [],
      }) =>
          WatchGeoBuilder.latestPingColor(
            txPings: [tx],
            rxPings: rxPings,
            discLogEntries: [discovery],
            traceLogEntries: traces,
          );

      expect(latest(), WatchColor.fromColor(PingColors.discSuccess));
      expect(
        latest(traces: [trace]),
        WatchColor.fromColor(PingColors.noResponse),
      );
      expect(
        latest(rxPings: [rx], traces: [trace]),
        WatchColor.fromColor(PingColors.rx),
      );
    });

    test('latest outcome uses the marker rule for multi-hop-only TX', () {
      final multiHop = _tx(
        DateTime(2026, 8, 12, 10),
        heard: const [
          HeardRepeater(
            repeaterId: '4e',
            snr: 6,
            pathHops: ['7a', '4e'],
          ),
        ],
      );

      final color = WatchGeoBuilder.latestPingColor(
        txPings: [multiHop],
        rxPings: const [],
        discLogEntries: const [],
        traceLogEntries: const [],
      );

      expect(color, WatchColor.fromColor(PingColors.rx));
    });

    test('discovery markers use response success and failure colours', () {
      final answered = _disc(
        DateTime(2026, 8, 12, 10, 1),
        discovered: true,
      );
      final unanswered = _disc(
        DateTime(2026, 8, 12, 10),
        discovered: false,
      );

      final pings = WatchGeoBuilder.buildPings(
        txPings: const [],
        rxPings: const [],
        discLogEntries: [answered, unanswered],
        traceLogEntries: const [],
      );

      final byTime = {for (final ping in pings) ping.at: ping};
      expect(byTime[answered.timestamp]!.kind, 'disc');
      expect(
        byTime[answered.timestamp]!.color,
        WatchColor.fromColor(PingColors.discSuccess),
      );
      expect(
        byTime[unanswered.timestamp]!.color,
        WatchColor.fromColor(PingColors.discFail),
      );
    });

    test('trace markers use the trace result colours', () {
      final answered = _trace(
        DateTime(2026, 8, 12, 10, 1),
        success: true,
      );
      final unanswered = _trace(
        DateTime(2026, 8, 12, 10),
        success: false,
      );

      final pings = WatchGeoBuilder.buildPings(
        txPings: const [],
        rxPings: const [],
        discLogEntries: const [],
        traceLogEntries: [answered, unanswered],
      );

      final byTime = {for (final ping in pings) ping.at: ping};
      expect(byTime[answered.timestamp]!.kind, 'trace');
      expect(
        byTime[answered.timestamp]!.color,
        WatchColor.fromColor(PingColors.traceSuccess),
      );
      expect(
        byTime[unanswered.timestamp]!.color,
        WatchColor.fromColor(PingColors.noResponse),
      );
    });

    test('the cap keeps the newest markers across mixed sources', () {
      final base = DateTime(2026, 8, 12, 10);
      final oldTx = List.generate(
        60,
        (i) => _tx(base.subtract(Duration(minutes: i + 1))),
      );
      final latestTx = _tx(base.add(const Duration(seconds: 1)));
      final latestRx = _rx(base.add(const Duration(seconds: 2)));
      final latestDisc = _disc(
        base.add(const Duration(seconds: 3)),
        discovered: true,
      );
      final latestTrace = _trace(
        base.add(const Duration(seconds: 4)),
        success: true,
      );

      final pings = WatchGeoBuilder.buildPings(
        txPings: [...oldTx, latestTx],
        rxPings: [latestRx],
        discLogEntries: [latestDisc],
        traceLogEntries: [latestTrace],
        cap: 4,
      );

      expect(pings.map((ping) => ping.kind), ['trace', 'disc', 'rx', 'tx']);
      expect(pings.map((ping) => ping.at), [
        latestTrace.timestamp,
        latestDisc.timestamp,
        latestRx.timestamp,
        latestTx.timestamp,
      ]);
    });

    test('all four marker types survive a realistic mixed history', () {
      final base = DateTime(2026, 8, 12, 10);

      final pings = WatchGeoBuilder.buildPings(
        txPings: List.generate(
          12,
          (i) => _tx(base.add(Duration(minutes: i * 4))),
        ),
        rxPings: List.generate(
          8,
          (i) => _rx(base.add(Duration(minutes: i * 6 + 1))),
        ),
        discLogEntries: List.generate(
          6,
          (i) => _disc(
            base.add(Duration(minutes: i * 8 + 2)),
            discovered: i.isEven,
          ),
        ),
        traceLogEntries: List.generate(
          4,
          (i) => _trace(
            base.add(Duration(minutes: i * 12 + 3)),
            success: i.isEven,
          ),
        ),
      );

      expect(pings.map((ping) => ping.kind).toSet(), {
        'tx',
        'rx',
        'disc',
        'trace',
      });
    });
  });

  group('buildRepeaters', () {
    test('excludes the (0,0) "location unknown" sentinel', () {
      final repeaters = [
        _repeater(id: 'a', lat: 0, lon: 0),
        _repeater(id: 'b', lat: 47.6, lon: -122.3),
      ];

      final built = WatchGeoBuilder.buildRepeaters(
        repeaters: repeaters,
        heardThisCycle: const {},
      );

      expect(built.map((r) => r.id), ['b']);
    });

    test('orders by distance from the fix and caps the list', () {
      final repeaters = [
        _repeater(id: 'far', lat: 48.6, lon: -122.3),
        _repeater(id: 'near', lat: 47.601, lon: -122.3),
        _repeater(id: 'mid', lat: 47.7, lon: -122.3),
      ];

      final built = WatchGeoBuilder.buildRepeaters(
        repeaters: repeaters,
        heardThisCycle: const {},
        lat: 47.6,
        lon: -122.3,
        cap: 2,
      );

      expect(built.map((r) => r.id), ['near', 'mid']);
    });

    test('marks an RX-only repeater heard through its unique hex prefix', () {
      final repeaters = [
        _repeater(id: '01', hexId: 'AA11', lat: 47.6, lon: -122.3),
        _repeater(id: '02', hexId: 'BB22', lat: 47.6, lon: -122.3),
        _repeater(id: '03', hexId: 'CC33', lat: 47.6, lon: -122.3),
      ];

      final built = WatchGeoBuilder.buildRepeaters(
        repeaters: repeaters,
        // This is the RX slot's path hash; no Top Heard entry is needed for
        // the repeater pin to receive its current-cycle ring.
        heardThisCycle: {'BB'},
      );

      expect(
        {for (final r in built) r.id: r.heardThisCycle},
        {'01': false, '02': true, '03': false},
      );
    });

    test('carries the full hex identity separately from the API id', () {
      final built = WatchGeoBuilder.buildRepeaters(
        repeaters: [
          _repeater(id: '01', hexId: '4E5D82', lat: 47.6, lon: -122.3),
        ],
        heardThisCycle: const {},
      );

      expect(built.single.id, '01');
      expect(built.single.hexId, '4E5D82');
    });
  });

  group('buildHeard — mirrors the map\'s Top Heard overlay', () {
    test('keeps the overlay order, with the RX slot trailing', () {
      final built = WatchGeoBuilder.buildHeard(
        top: const [
          (repeaterId: '4E5D', snr: 8.5, type: OverlayPingType.tx),
          (repeaterId: '77A1', snr: 2.25, type: OverlayPingType.disc),
        ],
        rxSlot: (repeaterId: 'B914', snr: 9.9),
        repeaterByHex: const {},
        topAt: DateTime(2026, 8, 12),
        rxAt: DateTime(2026, 8, 12, 0, 1),
      );

      // The RX slot trails even though its SNR is highest — it is a distinct
      // row on the map, not a competitor for the top three.
      expect(built.map((h) => h.id), ['4E5D', '77A1', 'B914']);
    });

    test('the RX row is purple and ping rows carry their own type colour', () {
      final built = WatchGeoBuilder.buildHeard(
        top: const [
          (repeaterId: 'AA', snr: 1, type: OverlayPingType.tx),
          (repeaterId: 'BB', snr: 1, type: OverlayPingType.disc),
        ],
        rxSlot: (repeaterId: 'CC', snr: 1),
        repeaterByHex: const {},
        topAt: DateTime(2026, 8, 12),
        rxAt: DateTime(2026, 8, 12),
      );

      expect(built[0].typeColor, WatchColor.fromColor(PingColors.txSuccess));
      expect(built[1].typeColor, WatchColor.fromColor(PingColors.discSuccess));
      expect(built[2].typeColor, WatchColor.fromColor(PingColors.rx));
    });

    test('never exceeds the wire cap of three rows plus the RX slot', () {
      final built = WatchGeoBuilder.buildHeard(
        top: const [
          (repeaterId: 'A', snr: 4, type: OverlayPingType.tx),
          (repeaterId: 'B', snr: 3, type: OverlayPingType.tx),
          (repeaterId: 'C', snr: 2, type: OverlayPingType.tx),
          (repeaterId: 'D', snr: 1, type: OverlayPingType.tx),
        ],
        rxSlot: (repeaterId: 'E', snr: 0),
        repeaterByHex: const {},
        topAt: DateTime(2026, 8, 12),
        rxAt: DateTime(2026, 8, 12),
      );

      expect(built.length, WatchWire.maxHeard);
    });

    test('uppercases the hex id and resolves name plus distance', () {
      final built = WatchGeoBuilder.buildHeard(
        top: const [(repeaterId: '4e5d', snr: 6, type: OverlayPingType.tx)],
        repeaterByHex: {
          '4E5D': _repeater(
              id: '01',
              hexId: '4E5D82',
              name: 'Capitol Hill',
              lat: 47.61,
              lon: -122.3),
        },
        topAt: DateTime(2026, 8, 12),
        rxAt: null,
        lat: 47.6,
        lon: -122.3,
      );

      expect(built.single.id, '4E5D');
      expect(built.single.name, 'Capitol Hill');
      expect(built.single.distanceM, closeTo(1112, 50));
    });

    test('leaves the name null when the hash resolves to nothing', () {
      final built = WatchGeoBuilder.buildHeard(
        top: const [(repeaterId: 'AB', snr: 1, type: OverlayPingType.tx)],
        repeaterByHex: const {},
        topAt: DateTime(2026, 8, 12),
        rxAt: null,
      );

      expect(built.single.id, 'AB');
      expect(built.single.name, isNull,
          reason: 'a confidently wrong name is worse than none');
      expect(built.single.distanceM, isNull);
    });
  });

  group('indexByHexPrefix', () {
    test('resolves a link from a path-hash prefix to the full hex', () {
      final repeater =
          _repeater(id: '01', hexId: '4E5D82', lat: 47.6, lon: -122.3);

      final linked = WatchGeoBuilder.resolveUniqueHexPrefixes(
        repeaters: [repeater],
        prefixes: const ['4E5D'],
      );

      expect(linked['4E5D'], same(repeater));
    });

    test('an ambiguous link prefix resolves to nothing', () {
      final linked = WatchGeoBuilder.resolveUniqueHexPrefixes(
        repeaters: [
          _repeater(id: '01', hexId: '4E5D82', lat: 47.6, lon: -122.3),
          _repeater(id: '02', hexId: '4E99F1', lat: 47.7, lon: -122.3),
        ],
        prefixes: const ['4E'],
      );

      expect(linked, isEmpty,
          reason: 'a line to the wrong repeater is worse than no line');
    });

    test('resolves a prefix owned by exactly one repeater', () {
      final index = WatchGeoBuilder.indexByHexPrefix([
        _repeater(id: '01', hexId: '4E5D82', lat: 47.6, lon: -122.3, name: 'A'),
        _repeater(id: '02', hexId: '77A1B0', lat: 47.6, lon: -122.3, name: 'B'),
      ], 4);

      expect(index['4E5D']?.name, 'A');
      expect(index['77A1']?.name, 'B');
    });

    test('drops prefixes shared by more than one repeater', () {
      // The exact collision a 1-byte path hash produces.
      final index = WatchGeoBuilder.indexByHexPrefix([
        _repeater(id: '01', hexId: '4E5D82', lat: 47.6, lon: -122.3, name: 'A'),
        _repeater(id: '02', hexId: '4E99F1', lat: 47.6, lon: -122.3, name: 'B'),
      ], 2);

      expect(index['4E'], isNull,
          reason: 'ambiguous prefixes must resolve to no name at all');
    });

    test('ignores repeaters whose hex is shorter than the prefix', () {
      final index = WatchGeoBuilder.indexByHexPrefix([
        _repeater(id: '01', hexId: '4E', lat: 47.6, lon: -122.3, name: 'A'),
      ], 4);

      expect(index, isEmpty);
    });
  });

  group('movedEnough', () {
    test('always sends the first fix', () {
      expect(
        WatchWire.movedEnough(
          lastLat: null,
          lastLon: null,
          lat: 47.6,
          lon: -122.3,
        ),
        isTrue,
      );
    });

    test('suppresses stationary GPS jitter', () {
      expect(
        WatchWire.movedEnough(
          lastLat: 47.6,
          lastLon: -122.3,
          lat: 47.60002,
          lon: -122.30002,
        ),
        isFalse,
      );
    });

    test('passes once the fix moves past the threshold', () {
      expect(
        WatchWire.movedEnough(
          lastLat: 47.6,
          lastLon: -122.3,
          lat: 47.6005,
          lon: -122.3,
        ),
        isTrue,
      );
    });
  });

  group('colour vision', () {
    test('ping colours follow the active palette', () {
      PingColors.setColorVisionType(ColorVisionType.none);
      final standard = WatchGeoBuilder.pingColor('tx', true);

      PingColors.setColorVisionType(ColorVisionType.protanopia);
      final protan = WatchGeoBuilder.pingColor('tx', true);

      expect(protan, isNot(standard));
      expect(protan, WatchColor.fromColor(PingColors.txSuccess));
    });

    test('every palette resolves all ping kinds without throwing', () {
      for (final type in ColorVisionType.values) {
        PingColors.setColorVisionType(type);
        for (final kind in ['tx', 'rx', 'disc', 'trace', 'bogus']) {
          for (final success in [true, false]) {
            expect(WatchGeoBuilder.pingColor(kind, success), isA<WatchColor>());
          }
        }
      }
    });
  });
}
