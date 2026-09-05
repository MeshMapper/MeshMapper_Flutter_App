import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/public_key.dart';

/// A full MeshCore public key is 32 bytes, so 64 hex characters. Anything
/// else is not a key the shared CARpeater list can identify.
void main() {
  const key = 'a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90';
  const upper = 'A1B2C3D4E5F60718293A4B5C6D7E8F90A1B2C3D4E5F60718293A4B5C6D7E8F90';

  test('normalizes case, whitespace and the 0x or ! prefixes', () {
    expect(normalizePublicKey(key), upper);
    expect(normalizePublicKey('  $upper  '), upper);
    expect(normalizePublicKey('0x$key'), upper);
    expect(normalizePublicKey('!$key'), upper);
  });

  test('rejects anything that is not exactly 64 hex', () {
    expect(normalizePublicKey(null), isNull);
    expect(normalizePublicKey(''), isNull);
    expect(normalizePublicKey(upper.substring(0, 63)), isNull);
    expect(normalizePublicKey('${upper}A'), isNull);
    expect(normalizePublicKey('ZZ${upper.substring(2)}'), isNull);
    expect(normalizePublicKey('4E12AB'), isNull);
  });

  test('isFullPublicKey mirrors normalize', () {
    expect(isFullPublicKey(key), isTrue);
    expect(isFullPublicKey('4E12AB'), isFalse);
    expect(isFullPublicKey(null), isFalse);
  });
}
