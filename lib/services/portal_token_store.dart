import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/debug_logger_io.dart';
import '../utils/public_key.dart';

/// The half-finished PKCE handshake for one sign-in attempt.
///
/// WHY this is PERSISTED rather than held in memory: on iOS the app is
/// routinely killed while the user is typing their portal password in Safari.
/// A memory-only verifier would fail the COMMON case, not an edge case. The
/// pair carries a 10-minute TTL and is burned after a single exchange attempt.
class PendingPkce {
  final String verifier;
  final String state;
  final DateTime createdAt;

  const PendingPkce({
    required this.verifier,
    required this.state,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'verifier': verifier,
        'state': state,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  /// Returns null for anything unusable — a partially written or corrupted
  /// blob must degrade to "no pending sign-in", never throw.
  static PendingPkce? fromJson(Map<String, dynamic> json) {
    final verifier = json['verifier'];
    final state = json['state'];
    final createdAt = json['created_at'];
    if (verifier is! String || verifier.isEmpty) return null;
    if (state is! String || state.isEmpty) return null;
    if (createdAt is! int) return null;
    return PendingPkce(
      verifier: verifier,
      state: state,
      createdAt: DateTime.fromMillisecondsSinceEpoch(createdAt),
    );
  }
}

/// Storage for the MyMeshMapper portal bearer token and the in-flight PKCE
/// pair. Split behind an interface so tests never touch the platform keystore.
abstract class PortalTokenStore {
  Future<String?> readToken();
  Future<void> writeToken(String token);
  Future<void> deleteToken();

  Future<PendingPkce?> readPendingPkce();
  Future<void> writePendingPkce(PendingPkce pending);
  Future<void> deletePendingPkce();
}

/// Repeater admin passwords, one entry per repeater public key. Keychain or
/// Keystore only: never logged, never sent to any server. The key is
/// normalized the same way as everywhere else in the app (upper-case 64 hex,
/// a `0x` or `!` prefix tolerated), so a caller can pass either form and read
/// back what it wrote.
abstract class RepeaterPasswordStore {
  Future<String?> readRepeaterPassword(String repeaterHex);
  Future<void> writeRepeaterPassword(String repeaterHex, String password);
  Future<void> deleteRepeaterPassword(String repeaterHex);
}

/// Keychain (iOS) / Keystore-backed EncryptedSharedPreferences (Android).
class SecureTokenStore implements PortalTokenStore, RepeaterPasswordStore {
  static const String tokenKey = 'portal_app_token';
  static const String pendingPkceKey = 'portal_pending_pkce';

  /// Named explicitly so the Android backup-exclusion rules can point at the
  /// exact file (`res/xml/backup_rules.xml`, `res/xml/data_extraction_rules.xml`).
  static const String androidPreferencesName = 'MeshMapperSecure';

  static const IOSOptions _iosOptions = IOSOptions(
    // The token must be readable by a background wardriving session on a
    // locked phone, but must never ride an iCloud backup to another device.
    accessibility: KeychainAccessibility.first_unlock_this_device,
  );

  static const AndroidOptions _androidOptions = AndroidOptions(
    encryptedSharedPreferences: true,
    sharedPreferencesName: androidPreferencesName,
    resetOnError: true,
  );

  final FlutterSecureStorage _storage;

  SecureTokenStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: _iosOptions,
              aOptions: _androidOptions,
            );

  /// Reads never throw.
  ///
  /// Android auto-backup restores the EncryptedSharedPreferences ciphertext
  /// without the hardware Keystore key that wrapped it, so the first read after
  /// a device transfer raises BadPaddingException. Nuking the store and
  /// reporting "signed out" is the only sane recovery — a throw here would take
  /// down `AppStateProvider._initialize()` and the whole app with it.
  Future<String?> _readSafely(String key) async {
    try {
      return await _storage.read(
        key: key,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
    } catch (e) {
      debugWarn('[ACCOUNT] Secure storage read failed for "${redactedKeyForLog(key)}" '
          '(${e.runtimeType}) — resetting to signed-out');
      try {
        await _storage.deleteAll(
          iOptions: _iosOptions,
          aOptions: _androidOptions,
        );
      } catch (deleteError) {
        debugError('[ACCOUNT] Secure storage reset failed: '
            '${deleteError.runtimeType}');
      }
      return null;
    }
  }

  /// Failures are swallowed by design — a completed write is NOT proof the
  /// value was persisted; callers learn that only from a later null read.
  Future<void> _writeSafely(String key, String value) async {
    try {
      await _storage.write(
        key: key,
        value: value,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
    } catch (e) {
      debugError('[ACCOUNT] Secure storage write failed for '
          '"${redactedKeyForLog(key)}" (${e.runtimeType})');
    }
  }

  /// Failures are swallowed by design — a completed delete is NOT proof the
  /// value is gone; sign-out must never hard-fail on a flaky keystore.
  Future<void> _deleteSafely(String key) async {
    try {
      await _storage.delete(
        key: key,
        iOptions: _iosOptions,
        aOptions: _androidOptions,
      );
    } catch (e) {
      debugWarn('[ACCOUNT] Secure storage delete failed for "${redactedKeyForLog(key)}" '
          '(${e.runtimeType})');
    }
  }

  @override
  Future<String?> readToken() => _readSafely(tokenKey);

  @override
  Future<void> writeToken(String token) => _writeSafely(tokenKey, token);

  @override
  Future<void> deleteToken() => _deleteSafely(tokenKey);

  @override
  Future<PendingPkce?> readPendingPkce() async {
    final raw = await _readSafely(pendingPkceKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) return null;
      return PendingPkce.fromJson(decoded);
    } catch (e) {
      debugWarn('[ACCOUNT] Pending PKCE blob unreadable — discarding');
      await _deleteSafely(pendingPkceKey);
      return null;
    }
  }

  @override
  Future<void> writePendingPkce(PendingPkce pending) =>
      _writeSafely(pendingPkceKey, jsonEncode(pending.toJson()));

  @override
  Future<void> deletePendingPkce() => _deleteSafely(pendingPkceKey);

  static const String repeaterPasswordPrefix = 'repeater_admin_pw_';

  static String repeaterPasswordKey(String repeaterHex) =>
      '$repeaterPasswordPrefix'
      '${normalizePublicKey(repeaterHex) ?? repeaterHex.trim().toUpperCase()}';

  /// [key] unchanged unless it is a repeater password key, in which case
  /// only the prefix plus the first 8 characters of the key material survive
  /// - the full 64-hex public key must never reach a log line.
  static String redactedKeyForLog(String key) {
    if (!key.startsWith(repeaterPasswordPrefix)) return key;
    final material = key.substring(repeaterPasswordPrefix.length);
    final shortened =
        material.length > 8 ? material.substring(0, 8) : material;
    return '$repeaterPasswordPrefix$shortened';
  }

  @override
  Future<String?> readRepeaterPassword(String repeaterHex) =>
      _readSafely(repeaterPasswordKey(repeaterHex));

  @override
  Future<void> writeRepeaterPassword(String repeaterHex, String password) =>
      _writeSafely(repeaterPasswordKey(repeaterHex), password);

  @override
  Future<void> deleteRepeaterPassword(String repeaterHex) =>
      _deleteSafely(repeaterPasswordKey(repeaterHex));
}

/// Test double. Also useful as a null-object on platforms with no keystore.
class InMemoryTokenStore implements PortalTokenStore, RepeaterPasswordStore {
  String? token;
  PendingPkce? pending;
  final Map<String, String> repeaterPasswords = {};

  @override
  Future<String?> readToken() async => token;

  @override
  Future<void> writeToken(String value) async => token = value;

  @override
  Future<void> deleteToken() async => token = null;

  @override
  Future<PendingPkce?> readPendingPkce() async => pending;

  @override
  Future<void> writePendingPkce(PendingPkce value) async => pending = value;

  @override
  Future<void> deletePendingPkce() async => pending = null;

  static String _key(String repeaterHex) =>
      normalizePublicKey(repeaterHex) ?? repeaterHex.trim().toUpperCase();

  @override
  Future<String?> readRepeaterPassword(String repeaterHex) async =>
      repeaterPasswords[_key(repeaterHex)];

  @override
  Future<void> writeRepeaterPassword(String repeaterHex, String password) async =>
      repeaterPasswords[_key(repeaterHex)] = password;

  @override
  Future<void> deleteRepeaterPassword(String repeaterHex) async =>
      repeaterPasswords.remove(_key(repeaterHex));
}
