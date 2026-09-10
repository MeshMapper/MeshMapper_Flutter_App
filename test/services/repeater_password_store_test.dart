import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/portal_token_store.dart';

/// Same seam as portal_token_store_test.dart: a FlutterSecureStorage
/// subclass, so no platform channel is touched.
class _MapStorage extends FlutterSecureStorage {
  final Map<String, String> values = {};
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      values[key];
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
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
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
    values.remove(key);
  }
}

void main() {
  final hex = 'ab' * 32;

  test('key naming is upper case and prefixed', () {
    expect(SecureTokenStore.repeaterPasswordKey(hex), 'repeater_admin_pw_${'AB' * 32}');
  });

  test('write, read, delete', () async {
    final storage = _MapStorage();
    final store = SecureTokenStore(storage: storage);
    expect(await store.readRepeaterPassword(hex), isNull);
    await store.writeRepeaterPassword(hex, 'hunter2');
    expect(storage.values.keys.single, 'repeater_admin_pw_${'AB' * 32}');
    expect(await store.readRepeaterPassword(hex.toUpperCase()), 'hunter2');
    await store.deleteRepeaterPassword(hex);
    expect(await store.readRepeaterPassword(hex), isNull);
  });

  test('in-memory store mirrors the contract', () async {
    final store = InMemoryTokenStore();
    await store.writeRepeaterPassword(hex, 'x');
    expect(await store.readRepeaterPassword(hex), 'x');
    await store.deleteRepeaterPassword(hex);
    expect(await store.readRepeaterPassword(hex), isNull);
  });
}
