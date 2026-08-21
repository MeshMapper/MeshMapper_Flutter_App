import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/portal_token_store.dart';

/// A keystore stand-in that can be told to fail.
///
/// `FlutterSecureStorage`'s read/write/delete/deleteAll are ordinary
/// overridable instance methods, so a subclass injected through
/// `SecureTokenStore({storage:})` exercises the real recovery paths with no
/// platform channel and no mocking package.
class _FakeSecureStorage extends FlutterSecureStorage {
  _FakeSecureStorage({
    Map<String, String>? values,
    this.throwOnRead = false,
    this.throwOnWrite = false,
    this.throwOnDelete = false,
    this.throwOnDeleteAll = false,
  }) : values = values ?? <String, String>{};

  final Map<String, String> values;
  final bool throwOnRead;
  final bool throwOnWrite;
  final bool throwOnDelete;
  final bool throwOnDeleteAll;

  bool deleteAllCalled = false;
  final List<String> deletedKeys = <String>[];
  final List<String> writtenKeys = <String>[];

  /// Shaped like the real failure: Android hands back a restored backup's
  /// ciphertext without the Keystore key that wrapped it.
  static PlatformException get _badPadding => PlatformException(
        code: 'Exception encountered',
        message: 'javax.crypto.BadPaddingException: pad block corrupted',
      );

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnRead) throw _badPadding;
    return values[key];
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnWrite) throw _badPadding;
    writtenKeys.add(key);
    if (value != null) values[key] = value;
  }

  @override
  Future<void> delete({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (throwOnDelete) throw _badPadding;
    deletedKeys.add(key);
    values.remove(key);
  }

  @override
  Future<void> deleteAll({
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    deleteAllCalled = true;
    if (throwOnDeleteAll) throw _badPadding;
    values.clear();
  }
}

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

  group('SecureTokenStore stores under the contract keys', () {
    test('the token round-trips under portal_app_token', () async {
      final fake = _FakeSecureStorage();
      final store = SecureTokenStore(storage: fake);

      await store.writeToken('t' * 64);

      expect(fake.values[SecureTokenStore.tokenKey], 't' * 64);
      expect(await store.readToken(), 't' * 64);

      await store.deleteToken();

      expect(fake.deletedKeys, contains(SecureTokenStore.tokenKey));
      expect(await store.readToken(), isNull);
    });

    test('the pending pair round-trips as JSON under portal_pending_pkce',
        () async {
      final fake = _FakeSecureStorage();
      final store = SecureTokenStore(storage: fake);
      final created = DateTime.fromMillisecondsSinceEpoch(1750000000000);

      await store.writePendingPkce(PendingPkce(
        verifier: 'v' * 43,
        state: 's' * 22,
        createdAt: created,
      ));

      expect(
          fake.values[SecureTokenStore.pendingPkceKey], contains('"verifier"'));

      final restored = await store.readPendingPkce();

      expect(restored, isNotNull);
      expect(restored!.verifier, 'v' * 43);
      expect(restored.state, 's' * 22);
      expect(restored.createdAt, created);

      await store.deletePendingPkce();

      expect(await store.readPendingPkce(), isNull);
    });

    test('an empty stored blob reads as no pending sign-in', () async {
      final store = SecureTokenStore(
        storage:
            _FakeSecureStorage(values: {SecureTokenStore.pendingPkceKey: ''}),
      );

      expect(await store.readPendingPkce(), isNull);
    });
  });

  group('SecureTokenStore reads never throw', () {
    test('a throwing read reports signed-out and nukes the store', () async {
      final fake = _FakeSecureStorage(throwOnRead: true);
      final store = SecureTokenStore(storage: fake);

      expect(await store.readToken(), isNull);
      expect(fake.deleteAllCalled, isTrue);
    });

    test('a throwing pending read also degrades to null', () async {
      final fake = _FakeSecureStorage(throwOnRead: true);
      final store = SecureTokenStore(storage: fake);

      expect(await store.readPendingPkce(), isNull);
      expect(fake.deleteAllCalled, isTrue);
    });

    test('a reset that itself fails still degrades to null, never throws',
        () async {
      final fake =
          _FakeSecureStorage(throwOnRead: true, throwOnDeleteAll: true);
      final store = SecureTokenStore(storage: fake);

      expect(await store.readToken(), isNull);
      expect(fake.deleteAllCalled, isTrue);
    });

    test('a corrupt pending blob is discarded, not thrown', () async {
      final fake = _FakeSecureStorage(
          values: {SecureTokenStore.pendingPkceKey: 'garbage{{'});
      final store = SecureTokenStore(storage: fake);

      expect(await store.readPendingPkce(), isNull);
      expect(fake.deletedKeys, contains(SecureTokenStore.pendingPkceKey));
    });

    test('a pending blob that is valid JSON but not an object reads as null',
        () async {
      // Left in place rather than deleted — it decodes fine, it just isn't a
      // pending sign-in. Reading it must still not throw.
      final store = SecureTokenStore(
        storage: _FakeSecureStorage(
          values: {SecureTokenStore.pendingPkceKey: '["not","a","map"]'},
        ),
      );

      expect(await store.readPendingPkce(), isNull);
    });

    test('a pending blob missing fields reads as null', () async {
      final store = SecureTokenStore(
        storage: _FakeSecureStorage(
          values: {SecureTokenStore.pendingPkceKey: '{"state":"s"}'},
        ),
      );

      expect(await store.readPendingPkce(), isNull);
    });
  });

  group('SecureTokenStore writes and deletes swallow failures', () {
    test('a throwing token write completes', () async {
      final store =
          SecureTokenStore(storage: _FakeSecureStorage(throwOnWrite: true));

      await expectLater(store.writeToken('t' * 64), completes);
    });

    test('a throwing token delete completes', () async {
      final store =
          SecureTokenStore(storage: _FakeSecureStorage(throwOnDelete: true));

      await expectLater(store.deleteToken(), completes);
    });

    test('a throwing pending write completes', () async {
      final store =
          SecureTokenStore(storage: _FakeSecureStorage(throwOnWrite: true));

      await expectLater(
        store.writePendingPkce(PendingPkce(
          verifier: 'v' * 43,
          state: 's' * 22,
          createdAt: DateTime.fromMillisecondsSinceEpoch(1750000000000),
        )),
        completes,
      );
    });

    test('a throwing pending delete completes', () async {
      final store =
          SecureTokenStore(storage: _FakeSecureStorage(throwOnDelete: true));

      await expectLater(store.deletePendingPkce(), completes);
    });
  });
}
