import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';

void main() {
  final base = {
    'id': '4E', 'hex_id': 'ab' * 32, 'name': 'Hill', 'lat': 1.0, 'lon': 2.0,
    'last_heard': 0, 'enabled': 1,
  };

  test('an old list has neither field', () {
    final r = Repeater.fromJson(base);
    expect(r.admins, isEmpty);
    expect(r.provenNeighbours, isEmpty);
  });

  test('admins are display names', () {
    final r = Repeater.fromJson({...base, 'admins': ['Alice', 'Bob', 7]});
    expect(r.admins, ['Alice', 'Bob']);
  });

  test('proven neighbours parse resolved and unresolved rows', () {
    final r = Repeater.fromJson({
      ...base,
      'proven_neighbours': [
        {'hex': 'cd' * 32, 'resolved': 1, 'snr': -3.5, 'heard_at': 1700000000},
        {'prefix': 'ef' * 8, 'resolved': 0, 'snr': null, 'heard_at': 1700000100},
        {'junk': true},
      ],
    });
    expect(r.provenNeighbours.length, 2);
    expect(r.provenNeighbours[0].hex, 'CD' * 32);
    expect(r.provenNeighbours[0].resolved, isTrue);
    expect(r.provenNeighbours[0].snr, -3.5);
    expect(r.provenNeighbours[1].hex, 'EF' * 8);
    expect(r.provenNeighbours[1].resolved, isFalse);
    expect(r.provenNeighbours[1].snr, isNull);
  });

  test('a proven neighbour whose key is too short to show is dropped', () {
    final r = Repeater.fromJson({
      ...base,
      'proven_neighbours': [
        {'hex': 'AB', 'resolved': 0, 'heard_at': 1700000000},
        {'prefix': 'ef' * 8, 'resolved': 0, 'heard_at': 1700000100},
      ],
    });
    expect(r.provenNeighbours.single.hex, 'EF' * 8);
  });

  test('toJson round trips both fields', () {
    final r = Repeater.fromJson({
      ...base,
      'admins': ['A'],
      'proven_neighbours': [{'hex': 'cd' * 32, 'resolved': true, 'snr': 1.0, 'heard_at': 5}],
    });
    final again = Repeater.fromJson(r.toJson());
    expect(again.admins, ['A']);
    expect(again.provenNeighbours.single.hex, 'CD' * 32);
  });
}
