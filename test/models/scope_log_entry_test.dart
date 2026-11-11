import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/scope_log_entry.dart';

void main() {
  test('every outcome reads in plain words', () {
    expect(ScopeLogOutcome.values.map((o) => o.label), [
      'Answered',
      'No response from repeater',
      'Sent as a flood by the radio',
      'Unreadable answer',
      'Radio error',
      'Radio contact list full',
      'Not uploaded: hourly limit reached',
    ]);
  });

  test('an entry keeps the names exactly as received', () {
    final entry = ScopeLogEntry(
      timestamp: DateTime(2026, 9, 26, 10),
      latitude: 45.1,
      longitude: -75.2,
      repeaterId: 'AB',
      pubkeyHex: 'AB' * 32,
      outcome: ScopeLogOutcome.answered,
      scopes: const ['Ottawa', '*', 'west'],
    );
    expect(entry.scopes, ['Ottawa', '*', 'west']);
    expect(entry.outcome.label, 'Answered');
    final empty = ScopeLogEntry(
      timestamp: DateTime(2026, 9, 26, 10),
      latitude: 0,
      longitude: 0,
      repeaterId: 'CD',
      pubkeyHex: 'CD',
      outcome: ScopeLogOutcome.noResponse,
    );
    expect(empty.scopes, isNull);
  });

  test('timeString is zero-padded HH:MM:SS', () {
    final entry = ScopeLogEntry(
      timestamp: DateTime(2026, 9, 26, 9, 4, 7),
      latitude: 45.1,
      longitude: -75.2,
      repeaterId: 'AB',
      pubkeyHex: 'AB' * 32,
      outcome: ScopeLogOutcome.answered,
      scopes: const ['Ottawa'],
    );
    expect(entry.timeString, '09:04:07');
  });

  test('locationString is 5 decimal places', () {
    final entry = ScopeLogEntry(
      timestamp: DateTime(2026, 9, 26, 10),
      latitude: 45.123456,
      longitude: -75.234567,
      repeaterId: 'AB',
      pubkeyHex: 'AB' * 32,
      outcome: ScopeLogOutcome.answered,
    );
    expect(entry.locationString, '45.12346,-75.23457');
  });

  group('toCsv', () {
    test('an answered entry lists its scope names, semicolon-joined', () {
      final entry = ScopeLogEntry(
        timestamp: DateTime.utc(2026, 9, 26, 10, 0, 0),
        latitude: 45.1,
        longitude: -75.2,
        repeaterId: 'AB',
        pubkeyHex: 'AB' * 32,
        outcome: ScopeLogOutcome.answered,
        scopes: const ['Ottawa', '*', 'west'],
      );
      expect(entry.toCsv(),
          '2026-09-26T10:00:00.000Z,45.1,-75.2,AB,answered,"Ottawa;*;west"');
    });

    test('an outcome with no scopes carries an empty quoted field', () {
      final entry = ScopeLogEntry(
        timestamp: DateTime.utc(2026, 9, 26, 10, 0, 0),
        latitude: 45.1,
        longitude: -75.2,
        repeaterId: 'AB',
        pubkeyHex: 'AB' * 32,
        outcome: ScopeLogOutcome.noResponse,
      );
      expect(entry.toCsv(),
          '2026-09-26T10:00:00.000Z,45.1,-75.2,AB,noResponse,""');
    });

    test('a radio-contacts-full entry carries its own outcome word', () {
      final entry = ScopeLogEntry(
        timestamp: DateTime.utc(2026, 9, 26, 10, 0, 0),
        latitude: 45.1,
        longitude: -75.2,
        repeaterId: 'AB',
        pubkeyHex: 'AB' * 32,
        outcome: ScopeLogOutcome.radioContactsFull,
      );
      expect(entry.toCsv(),
          '2026-09-26T10:00:00.000Z,45.1,-75.2,AB,radioContactsFull,""');
    });

    test('an answered entry with an empty scope list still quotes empty', () {
      final entry = ScopeLogEntry(
        timestamp: DateTime.utc(2026, 9, 26, 10, 0, 0),
        latitude: 0,
        longitude: 0,
        repeaterId: 'CD',
        pubkeyHex: 'CD' * 32,
        outcome: ScopeLogOutcome.answered,
        scopes: const [],
      );
      expect(
          entry.toCsv(), '2026-09-26T10:00:00.000Z,0.0,0.0,CD,answered,""');
    });
  });
}
