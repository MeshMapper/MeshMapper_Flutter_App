import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../models/device_catalog.dart';
import '../models/device_model.dart';
import '../utils/debug_logger_io.dart';
import 'api_service.dart';
import 'device_model_matcher.dart';

typedef DeviceCatalogFetcher = Future<DeviceCatalog?> Function();
typedef UnknownDeviceReporter = Future<DeviceReportAcknowledgement?> Function(
  String manufacturer,
  String appVersion,
  String? firmwareVersion,
);

abstract interface class DeviceCatalogStorage {
  /// Reloads durable values, discarding speculative process-cache writes.
  Future<void> reload();
  String? getString(String key);
  Future<bool> setString(String key, String value);
  Future<bool> remove(String key);
}

class SharedPreferencesDeviceCatalogStorage implements DeviceCatalogStorage {
  final SharedPreferences _preferences;

  SharedPreferencesDeviceCatalogStorage(this._preferences);

  @override
  Future<void> reload() => _preferences.reload();

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

  /// A connect-time retry never starts sooner than this after the previous
  /// refresh ended, so a dead link cannot turn every connect into a fetch.
  static const Duration connectRetryFloor = Duration(seconds: 30);

  /// The longest a connect resolve blocks on a refresh, whatever deadline that
  /// refresh is running to. Resolution happens at workflow step 4, before the
  /// first radio write of the handshake, and `handshakeRerunWindow` in
  /// `ble_connect_retry_policy.dart` gives a link that dies right after the
  /// transport connect 20 s to earn its one-shot workflow rerun, sized for a
  /// single 15 s first-write timeout. Spending a whole fetch deadline here
  /// would push a dying link past that window and lose the rerun, so a fetch
  /// that has not landed by now is simply unknown for this connection. The
  /// fetch itself keeps running to its own deadline and lands in the cache for
  /// the next connect.
  static const Duration connectWaitCap = Duration(seconds: 3);

  final DeviceCatalogFetcher _fetchCatalog;
  final UnknownDeviceReporter _reportUnknown;
  final Future<DeviceCatalogStorage> Function() _loadStorage;
  final Duration _launchTimeout;
  final DateTime Function() _now;

  DeviceCatalogStorage? _storage;
  Future<void>? _initializeFuture;
  DeviceCatalog? _catalog;
  Future<void>? _refreshFuture;
  DateTime? _refreshDeadline;
  bool _refreshInFlight = false;
  DateTime? _lastRefreshEnded;
  Future<void> _outboxChain = Future<void>.value();
  final Set<String> _attempted = <String>{};
  final String _outboxLaunchNonce = const Uuid().v4();
  int _outboxObservation = 0;
  static final RegExp _generationToken = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}:[1-9][0-9]*$',
  );

  DeviceModelService({
    DeviceCatalogFetcher? fetchCatalog,
    UnknownDeviceReporter? reportUnknown,
    Future<SharedPreferences> Function()? loadPreferences,
    Future<DeviceCatalogStorage> Function()? loadStorage,
    Duration launchTimeout = const Duration(seconds: 10),
    DateTime Function()? now,
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
        _launchTimeout = launchTimeout,
        _now = now ?? DateTime.now;

  bool get isLoaded => _storage != null;
  List<DeviceModel> get models =>
      List.unmodifiable(_catalog?.devices ?? const []);
  DeviceCatalog? get catalog => _catalog;
  Future<void> get refreshFuture => _refreshFuture ?? Future<void>.value();

  /// Loads only local storage, then begins the single non-blocking refresh.
  Future<void> initialize() => _initializeFuture ??= _initialize();

  Future<void> _initialize() async {
    try {
      final storage = await _loadStorage();
      // SharedPreferences updates its process cache before a write is
      // accepted. A reconstructed service must read the durable pointer.
      await storage.reload();
      // Read before publishing the storage, so a getString that throws leaves
      // the documented "no cache, no storage" state with nothing to undo.
      final cached = _readCommittedCatalog(storage);
      _storage = storage;
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
    } catch (error) {
      // Startup awaits this call, so a platform-channel or corrupt-prefs
      // failure must leave the service without storage instead of throwing
      // out and skipping every load after it.
      debugError('[MODEL] Device catalog storage unavailable: $error');
    }
    _startRefresh();
  }

  /// Arms one refresh with a fresh deadline. Callers check the guards first.
  void _startRefresh() {
    _refreshInFlight = true;
    _refreshDeadline = _now().add(_launchTimeout);
    _refreshFuture = _refresh();
  }

  /// True when a connect-time caller with no catalog may arm its own refresh.
  bool _canRetryRefresh() {
    if (_refreshInFlight) return false;
    final ended = _lastRefreshEnded;
    return ended == null || _now().difference(ended) >= connectRetryFloor;
  }

  /// Compatibility name for the app's existing initialization call.
  Future<void> loadModels() => initialize();

  Future<void> _refresh() async {
    try {
      DeviceCatalog? fetched;
      try {
        fetched = await _fetchCatalog();
      } catch (error) {
        debugWarn('[MODEL] Device catalog refresh failed: $error');
        return;
      }
      if (fetched == null) return;
      final encoded = fetched.toJsonString();
      if (utf8.encode(encoded).length > DeviceCatalog.maxEncodedBytes) return;
      if (!await _persist(encoded)) {
        // A cache that refuses the write still leaves a validated catalog in
        // hand. Publishing it keeps this process recognizing radios.
        debugWarn('[MODEL] Device catalog kept in memory for this launch only');
      }
      _catalog = fetched;
      unawaited(_drainOutbox(afterSuccessfulRefresh: true));
    } finally {
      _refreshInFlight = false;
      _lastRefreshEnded = _now();
    }
  }

  /// Publishes the encoded catalog to the inactive slot, then the pointer.
  /// A refused or failed write leaves the committed cache exactly as it was.
  Future<bool> _persist(String encoded) async {
    final storage = _storage;
    if (storage == null) return false;
    final activeSlot = storage.getString(_catalogPointerKey);
    final inactiveSlot = activeSlot == 'a' ? 'b' : 'a';
    final inactiveKey =
        inactiveSlot == 'a' ? _catalogSlotAKey : _catalogSlotBKey;
    try {
      if (!await storage.setString(inactiveKey, encoded)) return false;
      return await storage.setString(_catalogPointerKey, inactiveSlot);
    } catch (error) {
      debugWarn('[MODEL] Device catalog cache write failed: $error');
      return false;
    }
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
    if (_catalog == null && _canRetryRefresh()) {
      // The launch refresh is the only fetch this process has made, and it
      // left nothing behind. One connect gets one more attempt.
      debugLog('[MODEL] No device catalog available, retrying the fetch');
      _startRefresh();
    }
    var current = _catalog;
    if (current == null) {
      final deadline = _refreshDeadline;
      if (deadline != null) {
        final remaining = deadline.difference(_now());
        final wait = remaining > connectWaitCap ? connectWaitCap : remaining;
        if (!wait.isNegative) {
          await Future.any<void>([
            refreshFuture,
            Future<void>.delayed(wait),
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
    _enqueueOutbox(() async {
      final storage = _storage;
      if (storage == null) return;
      if (matchDeviceModel(manufacturer, _catalog!.devices) != null) return;
      final entries = _readOutbox(storage);
      // Eviction removes the persisted entry, but its report can still be in
      // flight. Tokens must therefore outlive entries and never restart for a
      // reinserted identity. The launch nonce also separates service instances.
      final generation = '$_outboxLaunchNonce:${++_outboxObservation}';
      entries[normalized] = {
        'manufacturer': manufacturer,
        'app_version': appVersion,
        'firmware_version': firmwareVersion ?? '',
        'observed_at': DateTime.now().toUtc().toIso8601String(),
        'generation': generation,
      };
      _trimOutbox(entries);
      await _writeOutbox(storage, entries);
      // Refresh may finish while storage is publishing the observation.
      // Claim only persisted, still-unknown work, before the network await.
      if (matchDeviceModel(manufacturer, _catalog!.devices) == null &&
          _attempted.add(normalized)) {
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
      _isValidGeneration(value['generation']);

  bool _isValidGeneration(Object? value) =>
      // Positive integers are retained for outboxes saved by earlier versions.
      (value is int && value > 0) ||
      (value is String && _generationToken.hasMatch(value));

  Future<void> _writeOutbox(
    DeviceCatalogStorage storage,
    Map<String, Map<String, dynamic>> entries,
  ) async {
    try {
      if (!await storage.setString(
          outboxKey, jsonEncode({'version': 1, 'entries': entries}))) {
        throw StateError('Outbox storage rejected write');
      }
    } catch (_) {
      // Do not allow a failed speculative write to become the next read.
      await storage.reload();
      rethrow;
    }
  }

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
    _enqueueOutbox(() async {
      final storage = _storage;
      if (storage == null) return;
      final entries = _readOutbox(storage);
      if (entries[identity]?['generation'] == submitted['generation']) {
        entries.remove(identity);
        await _writeOutbox(storage, entries);
      }
    });
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
