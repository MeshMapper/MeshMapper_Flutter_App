import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/ping_data.dart';
import 'package:mesh_mapper/utils/marker_data_version.dart';

TxPing _zeroEchoPing(int i) => TxPing(
      latitude: 45.0 + i * 0.0001,
      longitude: -75.0,
      power: 22,
      timestamp: DateTime.utc(2026, 10, 6).add(Duration(seconds: i)),
      deviceId: 'dev',
    );

void main() {
  group('cappedListSignature', () {
    test('a 501st zero-echo ping into a full FIFO changes the signature', () {
      const cap = 500;
      final pings = [for (var i = 0; i < cap; i++) _zeroEchoPing(i)];
      final before = cappedListSignature(pings);

      // What AppStateProvider does at the cap: append, evict the oldest.
      pings.add(_zeroEchoPing(cap));
      pings.removeAt(0);

      expect(pings.length, cap);
      expect(cappedListSignature(pings), isNot(before));
    });

    test('newest-first lists (DISC, trace) also change at the cap', () {
      const cap = 500;
      final entries = [for (var i = 0; i < cap; i++) Object()];
      final before = cappedListSignature(entries);

      entries.insert(0, Object());
      entries.removeLast();

      expect(cappedListSignature(entries), isNot(before));
    });

    test('a pure eviction changes the signature', () {
      final entries = [Object(), Object(), Object()];
      final before = cappedListSignature(entries);
      entries.removeAt(0);
      expect(cappedListSignature(entries), isNot(before));
    });

    test('is stable when nothing changed', () {
      final entries = [Object(), Object()];
      expect(cappedListSignature(entries), cappedListSignature(entries));
      expect(cappedListSignature(const []), 0);
    });
  });
}
