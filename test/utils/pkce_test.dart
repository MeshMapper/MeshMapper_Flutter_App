import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/pkce.dart';

/// PKCE contract for the MyMeshMapper portal sign-in lane. The server rejects
/// anything that is not S256 and not exactly 43 base64url chars, so the shape
/// assertions below are the wire contract, not style preferences.
void main() {
  group('challengeFor', () {
    test('matches the RFC 7636 Appendix B vector', () {
      expect(
        PkcePair.challengeFor('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'),
        'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
      );
    });

    test('is deterministic', () {
      expect(PkcePair.challengeFor('abc'), PkcePair.challengeFor('abc'));
    });
  });

  group('generate', () {
    test('verifier is 43 base64url chars with no padding', () {
      final pair = PkcePair.generate();
      expect(pair.verifier.length, 43);
      expect(pair.verifier.contains('='), isFalse);
      expect(RegExp(r'^[A-Za-z0-9._~-]+$').hasMatch(pair.verifier), isTrue);
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(pair.verifier), isTrue);
    });

    test('challenge is 43 base64url chars with no padding', () {
      final pair = PkcePair.generate();
      expect(pair.challenge.length, 43);
      expect(pair.challenge.contains('='), isFalse);
      expect(RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(pair.challenge), isTrue);
    });

    test('challenge is the S256 of the verifier it shipped with', () {
      final pair = PkcePair.generate();
      expect(pair.challenge, PkcePair.challengeFor(pair.verifier));
    });

    test('state is an independent 22-char base64url value', () {
      final pair = PkcePair.generate();
      expect(pair.state.length, 22);
      expect(pair.state.contains('='), isFalse);
      // Must satisfy the server's state charset: [A-Za-z0-9._~-]{1,128}
      expect(RegExp(r'^[A-Za-z0-9._~-]{1,128}$').hasMatch(pair.state), isTrue);
      expect(pair.state, isNot(pair.verifier));
    });

    test('successive pairs are unique', () {
      final verifiers = <String>{};
      final states = <String>{};
      for (var i = 0; i < 50; i++) {
        final pair = PkcePair.generate();
        verifiers.add(pair.verifier);
        states.add(pair.state);
      }
      expect(verifiers.length, 50);
      expect(states.length, 50);
    });

    test('an injected Random makes generation reproducible', () {
      final a = PkcePair.generate(random: Random(42));
      final b = PkcePair.generate(random: Random(42));
      expect(a.verifier, b.verifier);
      expect(a.challenge, b.challenge);
      expect(a.state, b.state);
    });
  });
}
