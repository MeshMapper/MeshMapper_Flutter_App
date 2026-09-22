import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';

void main() {
  final base = {
    'id': '4E', 'hex_id': 'ab' * 32, 'name': 'Hill', 'lat': 1.0, 'lon': 2.0,
    'last_heard': 0, 'enabled': 1,
  };

  test('an old list has no admins', () {
    final r = Repeater.fromJson(base);
    expect(r.admins, isEmpty);
  });

  test('admins are display names', () {
    final r = Repeater.fromJson({...base, 'admins': ['Alice', 'Bob', 7]});
    expect(r.admins, ['Alice', 'Bob']);
  });

  test('admins round trip through toJson', () {
    final r = Repeater.fromJson({...base, 'admins': ['A']});
    expect(Repeater.fromJson(r.toJson()).admins, ['A']);
  });

  test('a repeater carries no neighbour list of its own', () {
    // Neighbours belong to the Manage sheet, read off the radio at the moment
    // they are fetched for upload. The server still sends `proven_neighbours`
    // on the repeater list; the app ignores it rather than echoing it back.
    final r = Repeater.fromJson({
      ...base,
      'proven_neighbours': [
        {'key': 'cd' * 32, 'resolved': 1, 'snr': -3.5, 'heard_at': 1700000000},
      ],
    });
    expect(r.toJson().containsKey('proven_neighbours'), isFalse);
  });
}
