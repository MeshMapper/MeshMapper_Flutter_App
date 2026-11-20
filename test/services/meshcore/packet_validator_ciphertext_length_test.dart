import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/crypto_service.dart';
import 'package:mesh_mapper/services/meshcore/packet_metadata.dart';
import 'package:mesh_mapper/services/meshcore/packet_validator.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

/// AES-ECB works on whole 16-byte blocks. A GRP_TXT whose ciphertext is not
/// a block multiple is malformed and must be dropped before decryption,
/// rather than reaching the cipher and failing with "Input buffer too short".
void main() {
  final key = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
  final hash = CryptoService.computeChannelHash(key);

  PacketValidator validator() => PacketValidator(allowedChannels: {
        hash: ChannelInfo(channelName: '#wardriving', key: key, hash: hash),
      });

  PacketMetadata groupText(List<int> ciphertext) {
    const header =
        (PayloadType.grpTxt << PacketHeader.typeShift) | RouteType.flood;
    return PacketMetadata.fromRawPacket(
      raw: Uint8List.fromList([
        header,
        0x00, // no hops
        hash,
        0, 0, // MAC
        ...ciphertext,
      ]),
      snr: 5.0,
      rssi: -90,
    );
  }

  test('ciphertext length check accepts only whole AES blocks', () {
    expect(CryptoService.isValidCiphertextLength(0), isFalse);
    expect(CryptoService.isValidCiphertextLength(15), isFalse);
    expect(CryptoService.isValidCiphertextLength(17), isFalse);
    expect(CryptoService.isValidCiphertextLength(16), isTrue);
    expect(CryptoService.isValidCiphertextLength(32), isTrue);
  });

  test('a 17-byte ciphertext is dropped before decryption', () async {
    final result =
        await validator().validate(groupText(List<int>.filled(17, 0xAA)));
    expect(result.valid, isFalse);
    expect(result.reason, 'bad ciphertext length');
  });

  test('an empty ciphertext is dropped before decryption', () async {
    final result = await validator().validate(groupText(const []));
    expect(result.valid, isFalse);
    expect(result.reason, 'bad ciphertext length');
  });

  test('a 32-byte ciphertext decrypts and is kept', () async {
    final plain = Uint8List.fromList(
        [0, 0, 0, 0, 0, ...'MM:hello wardriving'.codeUnits]); // 24 bytes
    final encrypted = CryptoService.encryptChannelMessage(plain, key);
    expect(encrypted.length, 32);

    final result = await validator().validate(groupText(encrypted));
    expect(result.reason, isNot('bad ciphertext length'));
    expect(result.valid, isTrue);
    expect(result.plaintext, startsWith('MM:hello wardriving'));
  });
}
