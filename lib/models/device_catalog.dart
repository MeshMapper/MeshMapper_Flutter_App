import 'dart:convert';

import '../services/device_model_matcher.dart';
import 'device_model.dart';

/// Fully validated public device catalog, safe to cache and match locally.
class DeviceCatalog {
  static const int maxDevices = 500;
  static const int maxAliasesPerDevice = 50;
  static const int maxEncodedBytes = 1024 * 1024;

  final int revision;
  final List<DeviceModel> devices;

  DeviceCatalog({required this.revision, required List<DeviceModel> devices})
      : devices = List.unmodifiable(devices);

  factory DeviceCatalog.fromJson(
    Map<String, dynamic> json, {
    int? encodedLength,
  }) {
    if (encodedLength != null && encodedLength > maxEncodedBytes) {
      throw const FormatException('Device catalog response is too large');
    }
    if (json['success'] != true || json['revision'] is! int) {
      throw const FormatException('Invalid device catalog envelope');
    }
    final revision = json['revision'] as int;
    final records = json['devices'];
    if (revision < 0 || records is! List || records.isEmpty || records.length > maxDevices) {
      throw const FormatException('Invalid device catalog bounds');
    }
    final devices = <DeviceModel>[];
    final identities = <String>{};
    final ids = <int>{};
    for (final record in records) {
      if (record is! Map) throw const FormatException('Invalid device record');
      final model = DeviceModel.fromJson(Map<String, dynamic>.from(record));
      if (!ids.add(model.id) || model.aliases.length > maxAliasesPerDevice) {
        throw const FormatException('Duplicate device or excessive aliases');
      }
      for (final identity in <String>[model.manufacturer, ...model.aliases]) {
        final normalized = normalizeDeviceIdentity(identity);
        if (normalized.isEmpty || !identities.add(normalized)) {
          throw const FormatException('Invalid catalog identity');
        }
      }
      devices.add(model);
    }
    final catalog = DeviceCatalog(revision: revision, devices: devices);
    if (utf8.encode(jsonEncode(catalog.toJson())).length > maxEncodedBytes) {
      throw const FormatException('Device catalog response is too large');
    }
    return catalog;
  }

  Map<String, dynamic> toJson() => {
        'success': true,
        'revision': revision,
        'devices': devices.map((model) => model.toJson()).toList(),
      };

  /// Stable JSON used for the validated local cache.
  String toJsonString() => jsonEncode(toJson());
}
