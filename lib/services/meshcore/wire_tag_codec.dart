import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Encodes/decodes the on-air TX "wire tag" that replaces plaintext GPS
/// coordinates on the `#wardriving` channel.
///
/// A tag is `"MM:" + 10 base64url chars` (13 chars total). It packs the origin
/// region, the **session date**, the session number, and the per-session ping
/// counter into 55 bits, then runs a keyed 4-round Feistel so it can only be
/// decoded with the shared secret.
///
/// Layout (MSB→LSB): `region(15) | date(15) | NNNN(14) | counter(11)` where
/// `date = (year-2020)*512 + month*32 + day`. The date IS encoded (unlike the
/// original 40-bit tag) so a recycled daily NNNN mints a globally-unique tag —
/// this is the "green TX → DEAD tile" fix. `decode` fully reconstructs the
/// session_id `(region)-(YYYYMMDD)-(NNNN)`; no external date context is needed.
///
/// This MUST stay byte-identical to the PHP `wireTagEncode`/`wireTagDecode`
/// twins — see `test/services/wire_tag_codec_test.dart` for the canonical
/// cross-language vectors.
///
/// Web safety: this app runs on web (dart2js), where the bitwise operators
/// `<<`, `>>`, `&`, `|` truncate to 32 bits. The packed value is up to 55 bits
/// (> 2^53, the exact-integer ceiling for JS doubles), so the codec NEVER
/// materializes the full value — it works on two ≤28-bit halves and keeps every
/// intermediate below 2^40, using plain arithmetic (`*`, `~/`, `%`) which is
/// exact below 2^53. Bitwise ops appear only on the two ≤28-bit Feistel halves
/// (always < 2^31).
class WireTagCodec {
  WireTagCodec._();

  /// Marker prefix that distinguishes a MeshMapper tag from ordinary chatter.
  static const String prefix = 'MM:';

  static const int _pow11 = 2048; // 2^11  (counter field)
  static const int _pow25 = 33554432; // 2^25  (date field shift)
  static const int _pow28 = 268435456; // 2^28  (Feistel half size)
  static const int _pow12 = 4096; // 2^12  (region within the high half)
  static const int _mask28 = 0xFFFFFFF; // 28 bits — safe (< 2^31)

  // Date sub-fields: date = (year - _yearBase)*_pow9 + month*_pow5 + day.
  static const int _yearBase = 2020;
  static const int _pow9 = 512; // year shift (6-bit year → 2020..2083)
  static const int _pow5 = 32; // month shift (4-bit month / 5-bit day)

  static int _regionPack(String iata) {
    final u = iata.toUpperCase();
    return (u.codeUnitAt(0) - 65) * 676 +
        (u.codeUnitAt(1) - 65) * 26 +
        (u.codeUnitAt(2) - 65);
  }

  static String _regionUnpack(int n) =>
      String.fromCharCodes([n ~/ 676 + 65, (n % 676) ~/ 26 + 65, n % 26 + 65]);

  /// Feistel round function: first 4 bytes of SHA-256(secret ‖ round ‖ half),
  /// masked to 28 bits. `half` (< 2^28) is serialized big-endian as 4 bytes.
  static int _f(List<int> secret, int half, int round) {
    final input = <int>[
      ...secret,
      round,
      (half ~/ 16777216) % 256, // 2^24
      (half ~/ 65536) % 256, // 2^16
      (half ~/ 256) % 256,
      half % 256,
    ];
    final d = sha256.convert(input).bytes;
    return (d[0] * 16777216 + d[1] * 65536 + d[2] * 256 + d[3]) % _pow28;
  }

  /// 4-round balanced Feistel on the two 28-bit halves `(hi, lo)`.
  /// Returns the transformed `(left, right)` pair — the full value is never
  /// formed (it would exceed 2^53 on web).
  static (int, int) _feistel(List<int> secret, int hi, int lo,
      {required bool decrypt}) {
    var l = hi;
    var r = lo;
    for (final round in decrypt ? const [3, 2, 1, 0] : const [0, 1, 2, 3]) {
      if (!decrypt) {
        final newL = r;
        r = (l ^ _f(secret, r, round)) & _mask28;
        l = newL;
      } else {
        final newR = l;
        l = (r ^ _f(secret, l, round)) & _mask28;
        r = newR;
      }
    }
    return (l, r);
  }

  /// Serialize the 56-bit value `hi*2^28 + lo` (each half < 2^28) as 7 bytes,
  /// big-endian — without ever forming the full integer.
  static Uint8List _toBytes7(int hi, int lo) {
    return Uint8List.fromList([
      (hi ~/ 1048576) % 256, // 2^20  → bits 48-55
      (hi ~/ 4096) % 256, // 2^12  → bits 40-47
      (hi ~/ 16) % 256, // 2^4   → bits 32-39
      (hi % 16) * 16 + (lo ~/ 16777216) % 16, // bits 24-31 (straddle)
      (lo ~/ 65536) % 256, // bits 16-23
      (lo ~/ 256) % 256, // bits 8-15
      lo % 256, // bits 0-7
    ]);
  }

  /// Inverse of [_toBytes7]: 7 bytes → `(hi, lo)`, each half < 2^28.
  static (int, int) _fromBytes7(List<int> b) {
    final lo = b[6] + b[5] * 256 + b[4] * 65536 + (b[3] % 16) * 16777216;
    final hi = (b[3] ~/ 16) + b[2] * 16 + b[1] * 4096 + b[0] * 1048576;
    return (hi, lo);
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
    // Defensive guard: offline-upload ids ("offline-YYYYMMDD-NNNN") are passive-only and must
    // never be wire-tag encoded — parts[0] would be the literal "offline", not a region code.
    // The offline flow never calls encode() (only the live TX path does); this protects against
    // an accidental future caller and a malformed id (which would otherwise RangeError on parts[2]).
    if (parts.length < 3 || parts[0].toLowerCase() == 'offline') {
      throw ArgumentError(
          'Cannot wire-tag encode an offline / non-region session id: $sessionId');
    }
    final ymd = parts[1];
    final year = int.parse(ymd.substring(0, 4));
    final month = int.parse(ymd.substring(4, 6));
    final day = int.parse(ymd.substring(6, 8));
    final date = (year - _yearBase) * _pow9 + month * _pow5 + day;

    // Pack the low 40 bits, then split at bit 28 into the two Feistel halves.
    // lowPart < 2^40, so it (and the carry) stay well below 2^53 — web-safe.
    final lowPart = date * _pow25 + int.parse(parts[2]) * _pow11 + counter;
    final lo = lowPart % _pow28;
    final hi = _regionPack(parts[0]) * _pow12 + lowPart ~/ _pow28;

    final (cl, cr) = _feistel(utf8.encode(key ?? ''), hi, lo, decrypt: false);
    return prefix + _b64url(_toBytes7(cl, cr));
  }

  /// Decode a wire body back to region / date / session# / counter using the
  /// key alone (no database needed). The session_id is fully recoverable as
  /// `region-YYYYMMDD-NNNN`.
  static ({
    String region,
    int year,
    int month,
    int day,
    int sessionNum,
    int counter
  }) decode(String body, String? key) {
    final token =
        body.startsWith(prefix) ? body.substring(prefix.length) : body;
    final (chi, clo) = _fromBytes7(_unb64url(token));
    final (hi, lo) = _feistel(utf8.encode(key ?? ''), chi, clo, decrypt: true);

    final region = hi ~/ _pow12;
    final lowPart = (hi % _pow12) * _pow28 + lo;
    final date = lowPart ~/ _pow25;
    final rem = lowPart % _pow25;
    return (
      region: _regionUnpack(region),
      year: date ~/ _pow9 + _yearBase,
      month: (date % _pow9) ~/ _pow5,
      day: date % _pow5,
      sessionNum: rem ~/ _pow11,
      counter: rem % _pow11,
    );
  }
}
