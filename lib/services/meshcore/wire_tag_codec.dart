import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Encodes/decodes the on-air TX "wire tag" that replaces plaintext GPS
/// coordinates on the `#wardriving` channel.
///
/// A tag is `"MM:" + 7 base64url chars` (10 chars total → a single 16-byte AES
/// block once the channel layer encrypts it). It packs the origin region, the
/// session number, and the per-session ping counter into 40 bits, then runs a
/// keyed 4-round Feistel so it can only be decoded with the shared secret.
///
/// The session *date* is intentionally NOT encoded — a decoder always holds a
/// receive timestamp (or, server-side, the full session_id), so the date is
/// supplied from context. The full session_id is reconstructed as
/// `(decoded region)-(date from context)-(decoded session#)`.
///
/// This MUST stay byte-identical to the PHP `wireTagEncode`/`wireTagDecode`
/// twins — see `test/services/wire_tag_codec_test.dart` for the canonical
/// cross-language vectors.
///
/// Web safety: this app runs on web (dart2js), where the bitwise operators
/// `<<`, `>>`, `&`, `|` truncate to 32 bits. Our packed value is up to 40 bits,
/// so anything that can exceed 31 bits uses plain arithmetic (`*`, `~/`, `%`),
/// which is exact for integers below 2^53. Bitwise ops are used only on the
/// two ≤20-bit Feistel halves, which are always < 2^31.
class WireTagCodec {
  WireTagCodec._();

  /// Marker prefix that distinguishes a MeshMapper tag from ordinary chatter.
  static const String prefix = 'MM:';

  static const int _pow11 = 2048; // 2^11  (counter field)
  static const int _pow20 = 1048576; // 2^20  (Feistel half)
  static const int _pow25 = 33554432; // 2^25  (region field shift)
  static const int _mask20 = 0xFFFFF; // 20 bits — safe (< 2^31)

  static int _regionPack(String iata) {
    final u = iata.toUpperCase();
    return (u.codeUnitAt(0) - 65) * 676 +
        (u.codeUnitAt(1) - 65) * 26 +
        (u.codeUnitAt(2) - 65);
  }

  static String _regionUnpack(int n) =>
      String.fromCharCodes([n ~/ 676 + 65, (n % 676) ~/ 26 + 65, n % 26 + 65]);

  /// Feistel round function: first 3 bytes of SHA-256(secret ‖ round ‖ half),
  /// masked to 20 bits. `half` is serialized big-endian as 3 bytes.
  static int _f(List<int> secret, int half, int round) {
    final input = <int>[
      ...secret,
      round,
      (half ~/ 65536) % 256,
      (half ~/ 256) % 256,
      half % 256,
    ];
    final d = sha256.convert(input).bytes;
    return (d[0] * 65536 + d[1] * 256 + d[2]) % _pow20;
  }

  static int _feistel(List<int> secret, int v, {required bool decrypt}) {
    var l = v ~/ _pow20; // top 20 bits
    var r = v % _pow20; // bottom 20 bits
    for (final round in decrypt ? const [3, 2, 1, 0] : const [0, 1, 2, 3]) {
      if (!decrypt) {
        final newL = r;
        r = (l ^ _f(secret, r, round)) & _mask20;
        l = newL;
      } else {
        final newR = l;
        l = (r ^ _f(secret, l, round)) & _mask20;
        r = newR;
      }
    }
    return l * _pow20 + r;
  }

  static Uint8List _toBytes5(int v) {
    final b = Uint8List(5);
    var x = v;
    for (var i = 4; i >= 0; i--) {
      b[i] = x % 256;
      x = x ~/ 256;
    }
    return b;
  }

  static int _fromBytes5(List<int> b) {
    var v = 0;
    for (final byte in b) {
      v = v * 256 + byte;
    }
    return v;
  }

  static String _b64url(List<int> bytes) =>
      base64Url.encode(bytes).replaceAll('=', '');

  static Uint8List _unb64url(String s) =>
      base64Url.decode(s + ('=' * ((4 - s.length % 4) % 4)));

  /// Encode `sessionId` (`IATA-YYYYMMDD-NNNN`) + `counter` into the wire body.
  /// `key` is the shared secret from `/auth`; null/empty uses the un-keyed
  /// fallback (still coord-free, just not key-protected).
  static String encode(String sessionId, int counter, String? key) {
    final parts = sessionId.split('-');
    final v = _regionPack(parts[0]) * _pow25 +
        int.parse(parts[2]) * _pow11 +
        counter;
    final cipher = _feistel(utf8.encode(key ?? ''), v, decrypt: false);
    return prefix + _b64url(_toBytes5(cipher));
  }

  /// Decode a wire body back to region / session# / counter using the key alone
  /// (no database needed). The date is not recoverable from the tag.
  static ({String region, int sessionNum, int counter}) decode(
      String body, String? key) {
    final token =
        body.startsWith(prefix) ? body.substring(prefix.length) : body;
    final v =
        _feistel(utf8.encode(key ?? ''), _fromBytes5(_unb64url(token)), decrypt: true);
    final region = v ~/ _pow25;
    final rem = v % _pow25;
    return (
      region: _regionUnpack(region),
      sessionNum: rem ~/ _pow11,
      counter: rem % _pow11,
    );
  }
}
