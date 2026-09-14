import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/device_catalog.dart';
import '../models/device_model.dart';
import 'api_service.dart';
import 'device_model_matcher.dart';

typedef DeviceCatalogFetcher = Future<DeviceCatalog?> Function();
typedef UnknownDeviceReporter = Future<DeviceReportAcknowledgement?> Function(
  String manufacturer,
  String appVersion,
  String? firmwareVersion,
);

abstract interface class DeviceCatalogStorage {
  String? getString(String key);
  Future<bool> setString(String key, String value);
  Future<bool> remove(String key);
}

class SharedPreferencesDeviceCatalogStorage implements DeviceCatalogStorage {
  final SharedPreferences _preferences;

  SharedPreferencesDeviceCatalogStorage(this._preferences);

  @override
  String? getString(String key) => _preferences.getString(key);

  @override
  Future<bool> remove(String key) => _preferences.remove(key);

  @override
  Future<bool> setString(String key, String value) =>
      _preferences.setString(key, value);
}

/// Owns the validated launch cache, one shared refresh and unknown reports.
class DeviceModelService {
  static const String catalogCacheKey = 'device_catalog_v1';
  static const String _catalogPointerKey = 'device_catalog_active_slot_v1';
  static const String _catalogSlotAKey = 'device_catalog_slot_a_v1';
  static const String _catalogSlotBKey = 'device_catalog_slot_b_v1';
  static const String outboxKey = 'device_catalog_unknown_outbox_v1';

  final DeviceCatalogFetcher _fetchCatalog;
  final UnknownDeviceReporter _reportUnknown;
  final Future<DeviceCatalogStorage> Function() _loadStorage;
  final Duration _launchTimeout;

  DeviceCatalogStorage? _storage;
  Future<void>? _initializeFuture;
  DeviceCatalog? _catalog;
  Future<void>? _refreshFuture;
  DateTime? _refreshDeadline;
  Future<void> _outboxChain = Future<void>.value();
  final Set<String> _attempted = <String>{};

  DeviceModelService({
    DeviceCatalogFetcher? fetchCatalog,
    UnknownDeviceReporter? reportUnknown,
    Future<SharedPreferences> Function()? loadPreferences,
    Future<DeviceCatalogStorage> Function()? loadStorage,
    Duration launchTimeout = const Duration(seconds: 10),
  })  : _fetchCatalog = fetchCatalog ?? ApiService().fetchDeviceCatalog,
        _reportUnknown = reportUnknown ??
            ((manufacturer, appVersion, firmwareVersion) =>
                ApiService().reportUnknownDevice(
                  manufacturer: manufacturer,
                  appVersion: appVersion,
                  firmwareVersion: firmwareVersion,
                )),
        _loadStorage = loadStorage ??
            (() async => SharedPreferencesDeviceCatalogStorage(
                  await (loadPreferences ?? SharedPreferences.getInstance)(),
                )),
        _launchTimeout = launchTimeout;

  bool get isLoaded => _storage != null;
  List<DeviceModel> get models =>
      List.unmodifiable(_catalog?.devices ?? const []);
  DeviceCatalog? get catalog => _catalog;
  Future<void> get refreshFuture => _refreshFuture ?? Future<void>.value();

  /// Loads only local storage, then begins the single non-blocking refresh.
  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    final storage = await _loadStorage();
    _storage = storage;
    final cached = _readCommittedCatalog(storage);
    if (cached != null) {
      try {
        final decoded = jsonDecode(cached);
        if (decoded is Map<String, dynamic>) {
          _catalog = DeviceCatalog.fromJson(decoded,
              encodedLength: utf8.encode(cached).length);
        }
      } catch (_) {
        // A corrupt local value is never a catalog fallback.
      }
    }
    _refreshDeadline = DateTime.now().add(_launchTimeout);
    _refreshFuture = _refresh();
  }

  /// Compatibility name for the app's existing initialization call.
  Future<void> loadModels() => initialize();

  Future<void> _refresh() async {
    DeviceCatalog? fetched;
    try {
      fetched = await _fetchCatalog();
    } catch (_) {
      return;
    }
    if (fetched == null) return;
    final storage = _storage;
    if (storage == null) return;
    final encoded = fetched.toJsonString();
    if (utf8.encode(encoded).length > DeviceCatalog.maxEncodedBytes) return;
    final activeSlot = storage.getString(_catalogPointerKey);
    final inactiveSlot = activeSlot == 'a' ? 'b' : 'a';
    final inactiveKey =
        inactiveSlot == 'a' ? _catalogSlotAKey : _catalogSlotBKey;
    try {
      if (!await storage.setString(inactiveKey, encoded)) {
        return;
      }
      if (!await storage.setString(_catalogPointerKey, inactiveSlot)) return;
    } catch (_) {
      return;
    }
    _catalog = fetched;
    unawaited(_drainOutbox(afterSuccessfulRefresh: true));
  }

  String? _readCommittedCatalog(DeviceCatalogStorage storage) {
    final activeSlot = storage.getString(_catalogPointerKey);
    if (activeSlot == 'a') return storage.getString(_catalogSlotAKey);
    if (activeSlot == 'b') return storage.getString(_catalogSlotBKey);
    return storage.getString(catalogCacheKey);
  }

  /// Resolves at protocol step 4 against the current catalog.
  Future<DeviceModel?> resolveForConnection(String manufacturer) async {
    await initialize();
    var current = _catalog;
    if (current == null) {
      final deadline = _refreshDeadline;
      if (deadline != null) {
        final remaining = deadline.difference(DateTime.now());
        if (!remaining.isNegative) {
          await Future.any<void>([
            refreshFuture,
            Future<void>.delayed(remaining),
          ]);
        }
      }
      current = _catalog;
    }
    return current == null
        ? null
        : matchDeviceModel(manufacturer, current.devices);
  }

  /// Invokes one transport handshake with the catalog resolver shared by every
  /// connection path. The handshake owns device query and self-info before it
  /// asks this resolver for the fixed model used by that connection.
  Future<T> runConnection<T>(
    Future<T> Function(Future<DeviceModel?> Function(String)) handshake,
  ) =>
      handshake(resolveForConnection);

  /// Queues a genuine unknown only when a valid catalog was available.
  void observeUnknownDevice({
    required String manufacturer,
    required String appVersion,
    String? firmwareVersion,
  }) {
    if (_catalog == null ||
        matchDeviceModel(manufacturer, _catalog!.devices) != null) {
      return;
    }
    final normalized = normalizeDeviceIdentity(manufacturer);
    if (normalized.isEmpty) return;
    final isFirstAttempt = _attempted.add(normalized);
    _enqueueOutbox(() async {
      final storage = _storage;
      if (storage == null) return;
      final entries = _readOutbox(storage);
      final previous = entries[normalized];
      final generation = (previous?['generation'] as int? ?? 0) + 1;
      entries[normalized] = {
        'manufacturer': manufacturer,
        'app_version': appVersion,
        'firmware_version': firmwareVersion ?? '',
        'observed_at': DateTime.now().toUtc().toIso8601String(),
        'generation': generation,
      };
      _trimOutbox(entries);
      await _writeOutbox(storage, entries);
      if (isFirstAttempt) {
        unawaited(_dispatchOne(normalized, entries[normalized]!));
      }
    });
  }

  void _enqueueOutbox(Future<void> Function() operation) {
    _outboxChain = _outboxChain
        .catchError((_) {})
        .then((_) => operation())
        .catchError((_) {});
  }

  Map<String, Map<String, dynamic>> _readOutbox(DeviceCatalogStorage storage) {
    final raw = storage.getString(outboxKey);
    if (raw == null) return <String, Map<String, dynamic>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['entries'] is! Map) {
        return <String, Map<String, dynamic>>{};
      }
      final entries = <String, Map<String, dynamic>>{};
      for (final entry in (decoded['entries'] as Map).entries) {
        if (entry.key is! String || entry.value is! Map) continue;
        final value = Map<String, dynamic>.from(entry.value as Map);
        if (_isValidOutboxEntry(value)) entries[entry.key as String] = value;
      }
      return entries;
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  bool _isValidOutboxEntry(Map<String, dynamic> value) =>
      value['manufacturer'] is String &&
      value['app_version'] is String &&
      value['firmware_version'] is String &&
      value['observed_at'] is String &&
      value['generation'] is int &&
      (value['generation'] as int) > 0;

  Future<void> _writeOutbox(
    DeviceCatalogStorage storage,
    Map<String, Map<String, dynamic>> entries,
  ) =>
      storage.setString(
          outboxKey, jsonEncode({'version': 1, 'entries': entries}));

  void _trimOutbox(Map<String, Map<String, dynamic>> entries) {
    if (entries.length <= 50) return;
    final oldest = entries.entries.toList()
      ..sort((a, b) => (a.value['observed_at'] as String)
          .compareTo(b.value['observed_at'] as String));
    for (final entry in oldest.take(entries.length - 50)) {
      entries.remove(entry.key);
    }
  }

  Future<void> _dispatchOne(
      String identity, Map<String, dynamic> submitted) async {
    DeviceReportAcknowledgement? acknowledgement;
    try {
      acknowledgement = await _reportUnknown(
        submitted['manufacturer'] as String,
        submitted['app_version'] as String,
        submitted['firmware_version'] as String,
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      return;
    }
    if (acknowledgement == null) return;
    final storage = _storage;
    if (storage == null) return;
    final entries = _readOutbox(storage);
    if (entries[identity]?['generation'] == submitted['generation']) {
      entries.remove(identity);
      try {
        await _writeOutbox(storage, entries);
      } catch (_) {
        // A report acknowledgement must not poison later outbox mutations.
      }
    }
  }

  Future<void> _drainOutbox({required bool afterSuccessfulRefresh}) {
    if (!afterSuccessfulRefresh || _catalog == null) {
      return Future<void>.value();
    }
    _enqueueOutbox(() async {
      final storage = _storage;
      if (storage == null) return;
      final entries = _readOutbox(storage);
      for (final identity in entries.keys.toList()) {
        if (matchDeviceModel(identity, _catalog!.devices) != null) {
          entries.remove(identity);
        }
      }
      await _writeOutbox(storage, entries);
      for (final entry in entries.entries) {
        if (_attempted.add(entry.key)) {
          unawaited(_dispatchOne(entry.key, entry.value));
        }
      }
    });
    return _outboxChain;
  }
}
