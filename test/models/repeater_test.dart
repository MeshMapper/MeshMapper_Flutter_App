import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/repeater.dart';

void main() {
  test('non-string hex and prefix values are dropped or fall back safely', () {
    expect(ProvenNeighbour.tryFromJson({'hex': 123}), isNull);
    expect(ProvenNeighbour.tryFromJson({'prefix': false}), isNull);

    final neighbour = ProvenNeighbour.tryFromJson({
      'hex': 123,
      'prefix': 'ab' * 8,
    });
    expect(neighbour!.hex, 'AB' * 8);
  });

  test('heard_at accepts numeric values and numeric strings', () {
    const num heardAt = 12.9;
    expect(
      ProvenNeighbour.tryFromJson({'hex': 'ab' * 8, 'heard_at': heardAt})!
          .heardAt,
      12,
    );
    expect(
      ProvenNeighbour.tryFromJson({'hex': 'cd' * 8, 'heard_at': '13.9'})!
          .heardAt,
      13,
    );
  });
}
