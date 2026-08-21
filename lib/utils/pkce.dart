import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A PKCE verifier/challenge pair plus an independent OAuth `state`, generated
/// for one MyMeshMapper portal sign-in attempt (RFC 7636, S256 only).
///
/// The portal REQUIRES `code_challenge_method=S256` and rejects a challenge
/// that is not exactly 43 base64url characters, so both values are emitted
/// unpadded. `state` is generated separately from the verifier so that a
/// leaked callback URL (which carries `state`) reveals nothing about the
/// verifier that will redeem the code.
class PkcePair {
  /// 43-char base64url (32 random bytes), sent only in the `token` exchange.
  final String verifier;

  /// base64url(SHA-256(ASCII(verifier))), sent in the authorize URL.
  final String challenge;

  /// 22-char base64url (16 random bytes), echoed back by the portal.
  final String state;

  const PkcePair({
    required this.verifier,
    required this.challenge,
    required this.state,
  });

  /// Generate a fresh pair. [random] exists for tests only — production always
  /// uses `Random.secure()`.
  static PkcePair generate({Random? random}) {
    final rng = random ?? Random.secure();
    final verifier = _base64UrlNoPad(_randomBytes(rng, 32));
    return PkcePair(
      verifier: verifier,
      challenge: challengeFor(verifier),
      state: _base64UrlNoPad(_randomBytes(rng, 16)),
    );
  }

  /// RFC 7636 §4.2: `BASE64URL-ENCODE(SHA256(ASCII(code_verifier)))`.
  static String challengeFor(String verifier) => _base64UrlNoPad(
        Uint8List.fromList(sha256.convert(ascii.encode(verifier)).bytes),
      );

  static Uint8List _randomBytes(Random rng, int count) {
    final bytes = Uint8List(count);
    for (var i = 0; i < count; i++) {
      bytes[i] = rng.nextInt(256);
    }
    return bytes;
  }

  static String _base64UrlNoPad(Uint8List bytes) =>
      base64UrlEncode(bytes).replaceAll('=', '');
}
