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

/// Owns the validated launch cache, one shared refresh and unknown reports.
class DeviceModelService {
  static const String catalogCacheKey = 'device_catalog_v1';
  static const String outboxKey = 'device_catalog_unknown_outbox_v1';

  final DeviceCatalogFetcher _fetchCatalog;
  final UnknownDeviceReporter _reportUnknown;
  final Future<SharedPreferences> Function() _loadPreferences;
  final Duration _launchTimeout;

  SharedPreferences? _preferences;
  DeviceCatalog? _catalog;
  Future<void>? _refreshFuture;
  DateTime? _refreshDeadline;
  Future<void> _outboxChain = Future<void>.value();
  final Set<String> _attempted = <String>{};

  DeviceModelService({
    DeviceCatalogFetcher? fetchCatalog,
    UnknownDeviceReporter? reportUnknown,
    Future<SharedPreferences> Function()? loadPreferences,
    Duration launchTimeout = const Duration(seconds: 10),
  })  : _fetchCatalog = fetchCatalog ?? ApiService().fetchDeviceCatalog,
        _reportUnknown = reportUnknown ??
            ((manufacturer, appVersion, firmwareVersion) =>
                ApiService().reportUnknownDevice(
                  manufacturer: manufacturer,
                  appVersion: appVersion,
                  firmwareVersion: firmwareVersion,
                )),
        _loadPreferences = loadPreferences ?? SharedPreferences.getInstance,
        _launchTimeout = launchTimeout;

  bool get isLoaded => _preferences != null;
  List<DeviceModel> get models =>
      List.unmodifiable(_catalog?.devices ?? const []);
  DeviceCatalog? get catalog => _catalog;
  Future<void> get refreshFuture => _refreshFuture ?? Future<void>.value();

  /// Loads only local storage, then begins the single non-blocking refresh.
  Future<void> initialize() async {
    if (_preferences != null) return;
    final preferences = await _loadPreferences();
    _preferences = preferences;
    final cached = preferences.getString(catalogCacheKey);
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
    final preferences = _preferences;
    if (preferences == null) return;
    final encoded = fetched.toJsonString();
    if (utf8.encode(encoded).length > DeviceCatalog.maxEncodedBytes) return;
    try {
      await preferences.setString(catalogCacheKey, encoded);
    } catch (_) {
      return;
    }
    _catalog = fetched;
    await _drainOutbox(afterSuccessfulRefresh: true);
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
    _outboxChain = _outboxChain.then((_) async {
      final preferences = _preferences;
      if (preferences == null) return;
      final entries = _readOutbox(preferences);
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
      await _writeOutbox(preferences, entries);
      if (isFirstAttempt) await _dispatchOne(normalized, entries[normalized]!);
    });
  }

  Map<String, Map<String, dynamic>> _readOutbox(SharedPreferences preferences) {
    final raw = preferences.getString(outboxKey);
    if (raw == null) return <String, Map<String, dynamic>>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map ||
          decoded['version'] != 1 ||
          decoded['entries'] is! Map) {
        return <String, Map<String, dynamic>>{};
      }
      return (decoded['entries'] as Map).map((key, value) => MapEntry(
            key.toString(),
            Map<String, dynamic>.from(value as Map),
          ));
    } catch (_) {
      return <String, Map<String, dynamic>>{};
    }
  }

  Future<void> _writeOutbox(
    SharedPreferences preferences,
    Map<String, Map<String, dynamic>> entries,
  ) =>
      preferences.setString(
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
    final acknowledgement = await _reportUnknown(
      submitted['manufacturer'] as String,
      submitted['app_version'] as String,
      submitted['firmware_version'] as String,
    ).timeout(const Duration(seconds: 10), onTimeout: () => null);
    if (acknowledgement == null) return;
    final preferences = _preferences;
    if (preferences == null) return;
    final entries = _readOutbox(preferences);
    if (entries[identity]?['generation'] == submitted['generation']) {
      entries.remove(identity);
      await _writeOutbox(preferences, entries);
    }
  }

  Future<void> _drainOutbox({required bool afterSuccessfulRefresh}) {
    if (!afterSuccessfulRefresh || _catalog == null) {
      return Future<void>.value();
    }
    _outboxChain = _outboxChain.then((_) async {
      final preferences = _preferences;
      if (preferences == null) return;
      final entries = _readOutbox(preferences);
      for (final identity in entries.keys.toList()) {
        if (matchDeviceModel(identity, _catalog!.devices) != null) {
          entries.remove(identity);
        }
      }
      await _writeOutbox(preferences, entries);
      for (final entry in entries.entries) {
        if (_attempted.add(entry.key)) {
          await _dispatchOne(entry.key, entry.value);
        }
      }
    });
    return _outboxChain;
  }
}
