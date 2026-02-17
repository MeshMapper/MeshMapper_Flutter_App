/// Remembered BLE device for quick reconnection
class RememberedDevice {
  final String id;
  final String name;
  final DateTime lastConnected;

  const RememberedDevice({
    required this.id,
    required this.name,
    required this.lastConnected,
  });

  /// Create from JSON (for persistence)
  factory RememberedDevice.fromJson(Map<String, dynamic> json) {
    return RememberedDevice(
      id: json['id'] as String,
      name: json['name'] as String,
      lastConnected: DateTime.parse(json['lastConnected'] as String),
    );
  }

  /// Convert to JSON (for persistence)
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'lastConnected': lastConnected.toIso8601String(),
    };
  }

  /// Get display name (stripped of MeshCore- prefix)
  String get displayName => name.replaceFirst('MeshCore-', '');
}
