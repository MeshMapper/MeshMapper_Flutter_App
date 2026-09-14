import '../models/device_model.dart';

/// Sanitizes a firmware identity for the shared server and Flutter contract.
String sanitizeDeviceIdentity(String value) {
  var sanitized = value.replaceAll(RegExp(r'[\x00-\x1F\x7F]'), '').trim();
  sanitized = sanitized.replaceFirst(
    RegExp(r'(?:\s*)?(?:nightly|stable|dev)-[a-f0-9]+$', caseSensitive: false),
    '',
  );
  return sanitized.trim();
}

/// Returns the exact normalized catalog identity, or an empty string.
String normalizeDeviceIdentity(String value) {
  final sanitized = sanitizeDeviceIdentity(value);
  final buffer = StringBuffer();
  for (final codeUnit in sanitized.codeUnits) {
    if (codeUnit >= 0x41 && codeUnit <= 0x5a) {
      buffer.writeCharCode(codeUnit + 0x20);
    } else if ((codeUnit >= 0x61 && codeUnit <= 0x7a) ||
        (codeUnit >= 0x30 && codeUnit <= 0x39)) {
      buffer.writeCharCode(codeUnit);
    }
  }
  return buffer.toString();
}

/// Finds a model only when exactly one distinct device matches the identity.
DeviceModel? matchDeviceModel(
    String manufacturer, Iterable<DeviceModel> models) {
  final identity = normalizeDeviceIdentity(manufacturer);
  if (identity.isEmpty) return null;
  final matches = <int, DeviceModel>{};
  for (final model in models) {
    final values = <String>[
      model.manufacturer,
      model.shortName,
      ...model.aliases
    ];
    if (values.any((value) => normalizeDeviceIdentity(value) == identity)) {
      matches[model.id] = model;
    }
  }
  return matches.length == 1 ? matches.values.single : null;
}
