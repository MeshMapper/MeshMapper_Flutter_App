import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/log_entry.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';

ScopeLogEntry _scope({
  DateTime? timestamp,
  ScopeLogOutcome outcome = ScopeLogOutcome.answered,
  List<String>? scopes,
}) {
  return ScopeLogEntry(
    timestamp: timestamp ?? DateTime(2026, 9, 26, 10),
    latitude: 45.1,
    longitude: -75.2,
    repeaterId: 'AB',
    pubkeyHex: 'AB' * 32,
    outcome: outcome,
    scopes: scopes,
  );
}

void main() {
  group('UnifiedPingLogEntry.asScopes', () {
    test('carries the entry through unchanged', () {
      final scope = _scope();
      final unified = UnifiedPingLogEntry(
          type: PingLogType.scopes, timestamp: scope.timestamp, entry: scope);
      expect(unified.asScopes, same(scope));
    });

    test('timeString, locationString and toCsv delegate to the entry', () {
      final scope = _scope(scopes: const ['Ottawa', '*']);
      final unified = UnifiedPingLogEntry(
          type: PingLogType.scopes, timestamp: scope.timestamp, entry: scope);
      expect(unified.timeString, scope.timeString);
      expect(unified.locationString, scope.locationString);
      expect(unified.toCsv(), 'SCOPES,${scope.toCsv()}');
    });
  });

  group('mergeUnifiedPingLog', () {
    test('merges scopes newest first alongside the other types', () {
      final scope = _scope(timestamp: DateTime(2026, 9, 26, 10, 0, 30));
      final tx = TxLogEntry(
        timestamp: DateTime(2026, 9, 26, 10, 0, 0),
        latitude: 45.1,
        longitude: -75.2,
        power: 0.3,
        events: const [],
      );
      final rx = RxLogEntry(
        timestamp: DateTime(2026, 9, 26, 10, 0, 45),
        repeaterId: 'CD',
        pathLength: 1,
        header: 0x11,
        latitude: 45.1,
        longitude: -75.2,
      );

      final merged = mergeUnifiedPingLog(
        tx: [tx],
        rx: [rx],
        disc: const [],
        trace: const [],
        scopes: [scope],
      );

      expect(merged.map((e) => e.type),
          [PingLogType.rx, PingLogType.scopes, PingLogType.tx]);
    });

    test('an empty scopes list is a no-op', () {
      final tx = TxLogEntry(
        timestamp: DateTime(2026, 9, 26, 10),
        latitude: 0,
        longitude: 0,
        power: 0.3,
        events: const [],
      );
      final merged = mergeUnifiedPingLog(
          tx: [tx],
          rx: const [],
          disc: const [],
          trace: const [],
          scopes: const []);
      expect(merged, hasLength(1));
      expect(merged.single.type, PingLogType.tx);
    });
  });
}
