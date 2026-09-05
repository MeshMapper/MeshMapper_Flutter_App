import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart'
    show OverlayPingType;
import 'package:mesh_mapper/services/external_surfaces/geo/external_surface_geo_builder.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_heard.dart';

void main() {
  final t0 = DateTime.utc(2026, 9, 5, 10, 3, 28);
  final beforeT0 = t0.subtract(const Duration(seconds: 5));
  String? nameFor(String id) => id == 'A1' ? 'Alpha' : null;

  group('buildLiveActivityHeard mirrors the map Top Heard box', () {
    test('rows follow the map order with the RX slot trailing', () {
      final result = buildLiveActivityHeard(
        top: const [
          (repeaterId: 'A1', snr: 8.5, type: OverlayPingType.tx),
          (repeaterId: 'B2', snr: 2.25, type: OverlayPingType.disc),
        ],
        topTotalCount: 2,
        rxSlot: (repeaterId: 'C3', snr: 9.9),
        topAt: t0,
        rxAt: t0,
        cycleStartedAt: beforeT0,
        nameFor: nameFor,
      );

      expect(
        result.repeaters.map((r) => r.id),
        ['A1', 'B2', 'C3'],
        reason: 'the RX slot is a trailing row on the map, never sorted '
            'ahead of the ping rows however strong it is',
      );
      expect(
        result.repeaters.first.typeColor?.toMap(),
        ExternalSurfaceGeoBuilder.overlayTypeColor(OverlayPingType.tx).toMap(),
      );
      expect(
        result.repeaters.last.typeColor?.toMap(),
        ExternalSurfaceGeoBuilder.overlayTypeColor(OverlayPingType.rx).toMap(),
      );
      expect(result.isCurrent, isTrue);
    });

    test('a silent ping keeps the rows and marks them not current', () {
      final result = buildLiveActivityHeard(
        top: const [(repeaterId: 'A1', snr: 8.5, type: OverlayPingType.tx)],
        topTotalCount: 1,
        rxSlot: null,
        topAt: t0,
        rxAt: null,
        cycleStartedAt: t0.add(const Duration(seconds: 15)),
        nameFor: nameFor,
      );

      expect(result.repeaters.map((r) => r.id), ['A1'],
          reason: 'a ping that hears nothing leaves the map box alone, '
              'so the card keeps the last rows too');
      expect(result.isCurrent, isFalse,
          reason: 'rows from before the latest send are last heard, not now');
      expect(result.totalCount, 1);
    });

    test('an RX slot sharing a top row id is not duplicated', () {
      // The SwiftUI ForEach identifies rows by id and cannot draw one twice.
      final result = buildLiveActivityHeard(
        top: const [(repeaterId: 'a1', snr: 5, type: OverlayPingType.tx)],
        topTotalCount: 1,
        rxSlot: (repeaterId: 'A1', snr: 9),
        topAt: t0,
        rxAt: t0,
        cycleStartedAt: beforeT0,
        nameFor: nameFor,
      );

      expect(result.repeaters.length, 1);
      expect(result.repeaters.single.id, 'A1');
      expect(result.repeaters.single.snr, 5,
          reason: 'the ping row is the map row; the RX slot only adds a '
              'repeater the ping did not hear');
      expect(result.totalCount, 1);
    });

    test('total count is the uncapped ping count plus one for a distinct RX',
        () {
      final result = buildLiveActivityHeard(
        top: const [
          (repeaterId: 'A1', snr: 8, type: OverlayPingType.disc),
          (repeaterId: 'B2', snr: 7, type: OverlayPingType.disc),
          (repeaterId: 'C3', snr: 6, type: OverlayPingType.disc),
        ],
        topTotalCount: 5,
        rxSlot: (repeaterId: 'D4', snr: 1),
        topAt: t0,
        rxAt: t0,
        cycleStartedAt: beforeT0,
        nameFor: nameFor,
      );

      expect(result.repeaters.length, 4);
      expect(result.totalCount, 6,
          reason: 'the header counts every repeater the ping heard, not '
              'only the three the box shows, plus the RX row');
    });

    test('a fresh RX during a silent cycle shows only the RX row', () {
      final result = buildLiveActivityHeard(
        top: const [(repeaterId: 'A1', snr: 8.5, type: OverlayPingType.tx)],
        topTotalCount: 1,
        rxSlot: (repeaterId: 'D4', snr: 1.5),
        topAt: t0,
        rxAt: t0.add(const Duration(seconds: 12)),
        cycleStartedAt: t0.add(const Duration(seconds: 10)),
        nameFor: nameFor,
      );

      expect(result.repeaters.map((r) => r.id), ['D4']);
      expect(result.isCurrent, isTrue);
      expect(result.totalCount, 1);
    });

    test('uppercases ids, resolves names and colours the SNR', () {
      final result = buildLiveActivityHeard(
        top: const [
          (repeaterId: 'a1', snr: 8.5, type: OverlayPingType.tx),
          (repeaterId: 'b2', snr: -3, type: OverlayPingType.tx),
        ],
        topTotalCount: 2,
        rxSlot: null,
        topAt: t0,
        rxAt: null,
        cycleStartedAt: beforeT0,
        nameFor: nameFor,
      );

      expect(result.repeaters.first.id, 'A1');
      expect(result.repeaters.first.name, 'Alpha');
      expect(result.repeaters.last.name, isNull);
      expect(
        result.repeaters.last.snrColor?.toMap(),
        ExternalSurfaceGeoBuilder.snrColor(-3).toMap(),
      );
    });

    test('a row with a non-finite SNR is dropped', () {
      final result = buildLiveActivityHeard(
        top: const [
          (repeaterId: 'A1', snr: double.nan, type: OverlayPingType.tx),
          (repeaterId: 'B2', snr: 2, type: OverlayPingType.tx),
        ],
        topTotalCount: 2,
        rxSlot: (repeaterId: 'C3', snr: double.infinity),
        topAt: t0,
        rxAt: t0,
        cycleStartedAt: beforeT0,
        nameFor: nameFor,
      );

      expect(result.repeaters.map((r) => r.id), ['B2']);
    });
  });
}
