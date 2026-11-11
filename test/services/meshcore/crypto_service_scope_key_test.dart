import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/crypto_service.dart';

void main() {
  group('CryptoService.deriveScopeKey', () {
    test('preserves case: YOW and yow derive different keys', () {
      final keyYOW = CryptoService.deriveScopeKey('YOW');
      final keyYow = CryptoService.deriveScopeKey('yow');

      expect(keyYOW, isNotEmpty);
      expect(keyYow, isNotEmpty);
      expect(keyYOW.length, equals(16));
      expect(keyYow.length, equals(16));
      expect(keyYOW, isNot(keyYow));
    });

    test('hash prefix equivalence: #yow and yow derive the same key', () {
      final keyWithHash = CryptoService.deriveScopeKey('#yow');
      final keyWithoutHash = CryptoService.deriveScopeKey('yow');

      expect(keyWithHash, equals(keyWithoutHash));
    });

    test('known vector: #yow matches SHA256 first 16 bytes', () {
      final key = CryptoService.deriveScopeKey('#yow');

      // SHA256("#yow") = 77cb2a064167fca81a2c22cb4fd85dfb (from firmware)
      final expectedKey = Uint8List.fromList([
        0x77, 0xcb, 0x2a, 0x06, 0x41, 0x67, 0xfc, 0xa8,
        0x1a, 0x2c, 0x22, 0xcb, 0x4f, 0xd8, 0x5d, 0xfb,
      ]);

      expect(key, equals(expectedKey));
    });

    test('yow (without hash) also matches known vector', () {
      final key = CryptoService.deriveScopeKey('yow');

      // Should match the same vector as #yow
      final expectedKey = Uint8List.fromList([
        0x77, 0xcb, 0x2a, 0x06, 0x41, 0x67, 0xfc, 0xa8,
        0x1a, 0x2c, 0x22, 0xcb, 0x4f, 0xd8, 0x5d, 0xfb,
      ]);

      expect(key, equals(expectedKey));
    });

    test('uppercase YOW derives different key from lowercase yow', () {
      final keyYOW = CryptoService.deriveScopeKey('YOW');
      final keyYow = CryptoService.deriveScopeKey('yow');

      // SHA256("#YOW") should be different from SHA256("#yow")
      expect(keyYOW, isNot(keyYow));
      expect(keyYOW.length, equals(16));
      expect(keyYow.length, equals(16));
    });

    test('mixed case is preserved', () {
      final keyMixed1 = CryptoService.deriveScopeKey('BrQ');
      final keyMixed2 = CryptoService.deriveScopeKey('brq');
      final keyMixed3 = CryptoService.deriveScopeKey('BRQ');

      expect(keyMixed1, isNot(keyMixed2));
      expect(keyMixed1, isNot(keyMixed3));
      expect(keyMixed2, isNot(keyMixed3));
    });
  });
}
