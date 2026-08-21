import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/portal_token_store.dart';

void main() {
  group('PendingPkce', () {
    test('round-trips through JSON', () {
      final created = DateTime.fromMillisecondsSinceEpoch(1750000000000);
      final original = PendingPkce(
        verifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk',
        state: 'Zm9vYmFyYmF6cXV4MTIzNA',
        createdAt: created,
      );

      final restored = PendingPkce.fromJson(original.toJson());

      expect(restored, isNotNull);
      expect(restored!.verifier, original.verifier);
      expect(restored.state, original.state);
      expect(restored.createdAt, created);
    });

    test('rejects a body with missing fields', () {
      expect(PendingPkce.fromJson(const {'state': 'x'}), isNull);
      expect(PendingPkce.fromJson(const {}), isNull);
    });

    test('rejects a body with a non-numeric timestamp', () {
      expect(
        PendingPkce.fromJson(
            const {'verifier': 'v', 'state': 's', 'created_at': 'nope'}),
        isNull,
      );
    });
  });

  group('InMemoryTokenStore', () {
    late InMemoryTokenStore store;

    setUp(() => store = InMemoryTokenStore());

    test('token write / read / delete', () async {
      expect(await store.readToken(), isNull);
      await store.writeToken('a' * 64);
      expect(await store.readToken(), 'a' * 64);
      await store.deleteToken();
      expect(await store.readToken(), isNull);
    });

    test('pending PKCE write / read / delete', () async {
      expect(await store.readPendingPkce(), isNull);
      final pending = PendingPkce(
        verifier: 'v' * 43,
        state: 's' * 22,
        createdAt: DateTime.fromMillisecondsSinceEpoch(1750000000000),
      );
      await store.writePendingPkce(pending);
      expect((await store.readPendingPkce())!.verifier, 'v' * 43);
      await store.deletePendingPkce();
      expect(await store.readPendingPkce(), isNull);
    });
  });

  group('key names are the wire contract', () {
    test('keys are stable', () {
      expect(SecureTokenStore.tokenKey, 'portal_app_token');
      expect(SecureTokenStore.pendingPkceKey, 'portal_pending_pkce');
      expect(SecureTokenStore.androidPreferencesName, 'MeshMapperSecure');
    });
  });
}
