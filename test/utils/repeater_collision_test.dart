import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';
import 'package:mesh_mapper/utils/repeater_collision.dart';

Repeater rep(
  String hex, {
  String? id,
  String name = 'repeater',
  int enabled = 1,
  int advertBytes = 1,
  int hopBytes = 1,
  bool multibyteCapable = false,
  double lat = 1,
  double lon = 2,
  int lastHeard = 3,
  String? iata,
  int? createdAt,
  int? staleTime,
  int? timeOffset,
  List<String> admins = const [],
  List<ProvenNeighbour> provenNeighbours = const [],
  bool backbone = false,
  double? backboneShare,
}) =>
    Repeater(
      id: id ?? hex.substring(0, 2),
      hexId: hex,
      name: name,
      lat: lat,
      lon: lon,
      lastHeard: lastHeard,
      enabled: enabled,
      iata: iata,
      createdAt: createdAt,
      staleTime: staleTime,
      hopBytes: hopBytes,
      advertBytes: advertBytes,
      multibyteCapable: multibyteCapable,
      timeOffset: timeOffset,
      admins: admins,
      provenNeighbours: provenNeighbours,
      backbone: backbone,
      backboneShare: backboneShare,
    );

void main() {
  group('Repeater identity fields', () {
    test('parses advert width and capability with compatible fallbacks', () {
      final explicit = Repeater.fromJson({
        'id': 'ABCD',
        'hex_id': 'ABCD1234',
        'name': 'wide',
        'lat': 1,
        'lon': 2,
        'last_heard': 3,
        'enabled': 1,
        'hop_bytes': 3,
        'advert_bytes': 2,
        'multibyte_capable': 1,
      });
      final fallback = Repeater.fromJson({
        'id': 'ABCD',
        'hex_id': 'ABCD1234',
        'lat': 1,
        'lon': 2,
        'hop_bytes': 3,
        'multibyte_capable': true,
      });

      expect(explicit.advertBytes, 2);
      expect(explicit.multibyteCapable, isTrue);
      expect(explicit.displayHexId(), 'ABCD');
      expect(explicit.displayHexId(overrideHopBytes: 3), 'ABCD12');
      expect(fallback.advertBytes, 3);
      expect(fallback.multibyteCapable, isTrue);
      expect(fallback.toJson(), containsPair('advert_bytes', 3));
      expect(fallback.toJson(), containsPair('multibyte_capable', 1));
    });

    test('display id cleans decorations and falls back to stored id', () {
      expect(rep('!0xAABBCC', advertBytes: 2).displayHexId(), 'AABB');
      expect(rep('', id: 'cafe', advertBytes: 2).displayHexId(), 'CAFE');
      expect(rcCleanHex('!0xAa-11'), 'aa-11');
    });
  });

  group('rcComputeExclusions', () {
    test('matches the captured RDU collision contract', () {
      final fixture = jsonDecode(File(
        'test/fixtures/repeater_collision_contract.json',
      ).readAsStringSync()) as Map<String, dynamic>;
      final input = (fixture['rdu_pair'] as List)
          .cast<Map<String, dynamic>>()
          .map(Repeater.fromJson)
          .toList();
      final expected =
          (fixture['php_expected'] as List).cast<Map<String, dynamic>>();

      final result = rcComputeExclusions(input);

      expect(
        result.map((r) => r.enabled == 2),
        expected.map((row) => row['excluded']),
      );
      expect(
        result.map((r) => r.displayHexId()),
        expected.map((row) => row['display']),
      );
      expect(result.map((r) => r.hexId), expected.map((row) => row['hex_id']));
      expect(repeaterConflictKind(result, result.first), '2');
    });

    test('exclusion is asymmetric for mixed capability', () {
      final narrow = rep(
        'AA11${'0' * 60}',
        advertBytes: 1,
        multibyteCapable: false,
      );
      final wide = rep(
        'AA22${'1' * 60}',
        advertBytes: 2,
        multibyteCapable: true,
      );

      final result = rcComputeExclusions([narrow, wide]);

      expect(result.map((r) => r.enabled), [2, 1]);
      expect(repeaterConflictKind(result, result[0]), 'ambiguous');
      expect(repeaterConflictKind(result, result[1]), '');
    });

    test('three-byte repeater can be enabled while retaining kind 2', () {
      final target = rep(
        'CAFE01${'0' * 58}',
        advertBytes: 3,
        multibyteCapable: true,
      );
      final neighbour = rep(
        'CAFE02${'1' * 58}',
        advertBytes: 3,
        multibyteCapable: true,
      );

      final result = rcComputeExclusions([target, neighbour]);

      expect(result.map((r) => r.enabled), [1, 1]);
      expect(repeaterConflictKind(result, result.first), '2');
      expect(repeaterConflictKind(result, result.last), '2');
    });

    test('folds twins at prefix and suffix threshold boundaries', () {
      final prefix24 = 'A' * 24;
      final suffix24 = 'B' * 24;
      final rows = [
        rep('$prefix24${'1' * 40}', enabled: 2, name: 'prefix loser'),
        rep('$prefix24${'2' * 40}', name: 'prefix winner'),
        rep('${'3' * 40}$suffix24', enabled: 2, name: 'suffix loser'),
        rep('${'4' * 40}$suffix24', name: 'suffix winner'),
        rep('${'C' * 23}0${'5' * 40}', name: 'below threshold'),
        rep('${'C' * 23}1${'6' * 40}', name: 'distinct'),
      ];

      final result = rcComputeExclusions(rows);

      expect(result, hasLength(4));
      expect(result.map((r) => r.name),
          containsAll(['prefix winner', 'suffix winner']));
      expect(result.where((r) => r.name.startsWith('prefix')), hasLength(1));
      expect(result.where((r) => r.name.startsWith('suffix')), hasLength(1));
    });

    test('twin choice prefers coordinates and fills missing coordinates', () {
      final shared = 'D' * 24;
      final coordinateLess = rep(
        '$shared${'1' * 40}',
        name: 'missing coordinates',
        lat: double.nan,
        lon: double.nan,
        advertBytes: 3,
        multibyteCapable: true,
      );
      final located = rep(
        '$shared${'2' * 40}',
        name: 'located',
        lat: 45,
        lon: -75,
      );

      final result = rcComputeExclusions([coordinateLess, located]);

      expect(result, hasLength(1));
      expect(result.single.name, 'located');
      expect(result.single.lat, 45);
      expect(result.single.lon, -75);
      expect(result.single.advertBytes, 3);
      expect(result.single.multibyteCapable, isTrue);
    });

    test('collapses a unique fragment but retains an ambiguous fragment', () {
      final uniqueParent = rep('0600${'A' * 60}', enabled: 2, advertBytes: 1);
      final uniqueFragment = rep(
        '0600',
        id: '0600',
        advertBytes: 3,
        multibyteCapable: true,
      );
      final ambiguousFragment = rep('AB', id: 'AB');
      final parent1 = rep('AB10${'1' * 60}');
      final parent2 = rep('AB20${'2' * 60}');

      final result = rcComputeExclusions([
        uniqueParent,
        uniqueFragment,
        ambiguousFragment,
        parent1,
        parent2,
      ]);

      expect(result.where((r) => r.hexId == '0600'), isEmpty);
      final merged = result.singleWhere((r) => r.hexId.startsWith('0600A'));
      expect(merged.advertBytes, 3);
      expect(merged.multibyteCapable, isTrue);
      expect(merged.enabled, 1);
      expect(result.where((r) => r.hexId == 'AB'), hasLength(1));
    });

    test('hidden repeater uses the web ambiguous conflict branch', () {
      final hidden = rep(
        'EF10${'A' * 60}',
        name: '🚫hidden',
        advertBytes: 3,
        multibyteCapable: true,
      );
      final other = rep(
        'EF20${'B' * 60}',
        advertBytes: 3,
        multibyteCapable: true,
      );

      expect(repeaterConflictKind([hidden, other], hidden), 'ambiguous');
    });

    test('all-distinct data is a metadata-preserving no-op', () {
      const neighbour =
          ProvenNeighbour(hex: '12345678', resolved: true, snr: 4);
      final original = rep(
        '1010${'A' * 60}',
        id: '10',
        name: 'metadata',
        enabled: 2,
        advertBytes: 2,
        hopBytes: 3,
        multibyteCapable: true,
        lat: 45,
        lon: -75,
        lastHeard: 99,
        iata: 'YOW',
        createdAt: 10,
        staleTime: 20,
        timeOffset: -3,
        admins: const ['admin'],
        provenNeighbours: const [neighbour],
        backbone: true,
        backboneShare: 0.4,
      );

      final result = rcComputeExclusions([original, rep('2020${'B' * 60}')]);
      final copy = result.first;

      expect(copy.toJson(), {
        ...original.toJson(),
        'enabled': 1,
      });
      expect(copy.admins, same(original.admins));
      expect(copy.provenNeighbours, same(original.provenNeighbours));
    });
  });
}
