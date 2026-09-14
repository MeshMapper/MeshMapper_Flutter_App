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
      ProvenNeighbour.tryFromJson({'hex': 'aa' * 8, 'heard_at': 11})!.heardAt,
      11,
    );
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

  test('heard_at drops non-finite numeric values and text', () {
    for (final value in [double.nan, double.infinity, double.negativeInfinity]) {
      expect(
        () => ProvenNeighbour.tryFromJson({'hex': 'ab' * 8, 'heard_at': value}),
        returnsNormally,
      );
      expect(
        ProvenNeighbour.tryFromJson({'hex': 'ab' * 8, 'heard_at': value})!.heardAt,
        isNull,
      );
    }
    for (final value in ['NaN', 'Infinity', '-Infinity']) {
      expect(
        () => ProvenNeighbour.tryFromJson({'hex': 'cd' * 8, 'heard_at': value}),
        returnsNormally,
      );
      expect(
        ProvenNeighbour.tryFromJson({'hex': 'cd' * 8, 'heard_at': value})!.heardAt,
        isNull,
      );
    }
  });
}
