import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/ping_data.dart';
import 'package:mesh_mapper/models/repeater.dart';
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
    test('merges TX and RX newest-first and caps the list', () {
      final base = DateTime(2026, 8, 12, 10);
      final tx = List.generate(40, (i) => _tx(base.add(Duration(minutes: i))));
      final rx = List.generate(40, (i) => _rx(base.add(Duration(seconds: i))));

      final pings = WatchGeoBuilder.buildPings(txPings: tx, rxPings: rx);

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

    test('marks heard-this-cycle by either short id or hex id', () {
      final repeaters = [
        _repeater(id: '01', hexId: 'AA11', lat: 47.6, lon: -122.3),
        _repeater(id: '02', hexId: 'BB22', lat: 47.6, lon: -122.3),
        _repeater(id: '03', hexId: 'CC33', lat: 47.6, lon: -122.3),
      ];

      final built = WatchGeoBuilder.buildRepeaters(
        repeaters: repeaters,
        heardThisCycle: {'01', 'BB22'},
      );

      expect(
        {for (final r in built) r.id: r.heardThisCycle},
        {'01': true, '02': true, '03': false},
      );
    });
  });

  group('buildHeard', () {
    test('sorts by SNR descending and caps at the wire limit', () {
      final heard = List.generate(
        12,
        (i) => HeardRepeater(repeaterId: 'r$i', snr: i.toDouble()),
      );

      final built = WatchGeoBuilder.buildHeard(
        heard: heard,
        repeaterById: const {},
        at: DateTime(2026, 8, 12),
      );

      expect(built.length, WatchWire.maxHeard);
      expect(built.first.snr, 11.0);
      expect(built.last.snr, 5.0);
    });

    test('a null SNR sorts last rather than crashing', () {
      final built = WatchGeoBuilder.buildHeard(
        heard: const [
          HeardRepeater(repeaterId: 'quiet'),
          HeardRepeater(repeaterId: 'loud', snr: 3),
        ],
        repeaterById: const {},
        at: DateTime(2026, 8, 12),
      );

      expect(built.map((h) => h.id), ['loud', 'quiet']);
      expect(built.last.snrColor, isNull);
    });

    test('resolves name and distance from the repeater directory', () {
      final built = WatchGeoBuilder.buildHeard(
        heard: const [HeardRepeater(repeaterId: '4e', snr: 6, rssi: -80)],
        repeaterById: {
          '4e': _repeater(id: '4e', name: 'Capitol Hill', lat: 47.61, lon: -122.3),
        },
        at: DateTime(2026, 8, 12),
        lat: 47.6,
        lon: -122.3,
      );

      expect(built.single.name, 'Capitol Hill');
      expect(built.single.distanceM, closeTo(1112, 50));
    });

    test('falls back to the uppercased id when the repeater is unknown', () {
      final built = WatchGeoBuilder.buildHeard(
        heard: const [HeardRepeater(repeaterId: 'ab')],
        repeaterById: const {},
        at: DateTime(2026, 8, 12),
      );

      expect(built.single.name, 'AB');
      expect(built.single.distanceM, isNull);
    });

    test('direct echoes report no hop count', () {
      final built = WatchGeoBuilder.buildHeard(
        heard: const [
          HeardRepeater(repeaterId: 'direct', snr: 9),
          HeardRepeater(repeaterId: 'relayed', snr: 8, pathHops: ['aa', 'bb']),
        ],
        repeaterById: const {},
        at: DateTime(2026, 8, 12),
      );

      expect(built[0].hops, isNull);
      expect(built[1].hops, 2);
    });
  });

  group('movedEnough', () {
    test('always sends the first fix', () {
      expect(
        WatchGeoBuilder.movedEnough(
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
        WatchGeoBuilder.movedEnough(
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
        WatchGeoBuilder.movedEnough(
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
