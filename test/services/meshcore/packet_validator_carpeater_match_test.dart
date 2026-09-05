import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/packet_validator.dart';

/// The stored CARpeater value is now a full 64-hex key; a path hop is 2 to 8
/// hex, so the match runs on the shorter of the two.
void main() {
  final key = 'AB' * 32;

  test('a hop at any width matches its own prefix of the full key', () {
    expect(PacketValidator.isCarpeaterIdMatch('AB', key), isTrue);
    expect(PacketValidator.isCarpeaterIdMatch('ABAB', key), isTrue);
    expect(PacketValidator.isCarpeaterIdMatch('ABABAB', key), isTrue);
    expect(PacketValidator.isCarpeaterIdMatch('ABABABAB', key), isTrue);
    expect(PacketValidator.isCarpeaterIdMatch('abab', key), isTrue);
  });

  test('a diverging prefix does not match', () {
    expect(PacketValidator.isCarpeaterIdMatch('AC', key), isFalse);
    expect(PacketValidator.isCarpeaterIdMatch('ABAC', key), isFalse);
    expect(PacketValidator.isCarpeaterIdMatch('', key), isFalse);
  });
}
