/// Represents a MeshCore device model with its power configuration.
/// 
/// This maps to the device-models.json database from the WebClient repo.
/// Power configuration is critical for PA amplifier models to prevent hardware damage.
class DeviceModel {
  /// Full manufacturer string reported by device (e.g., "Ikoka Stick-E22-30dBm (Xiao_nrf52)")
  final String manufacturer;
  
  /// Short display name (e.g., "Ikoka Stick")
  final String shortName;
  
  /// Power setting for wardrive.js (0.3, 0.6, 1.0, 2.0)
  /// CRITICAL: PA amplifier models require exact values
  final double power;
  
  /// Hardware platform (nrf52, esp32, esp32-s3, etc.)
  final String platform;
  
  /// Firmware TX power setting in dBm
  final int txPower;
  
  /// Additional notes about the device
  final String notes;

  const DeviceModel({
    required this.manufacturer,
    required this.shortName,
    required this.power,
    required this.platform,
    required this.txPower,
    required this.notes,
  });

  /// Parse from JSON object in device-models.json
  factory DeviceModel.fromJson(Map<String, dynamic> json) {
    return DeviceModel(
      manufacturer: json['manufacturer'] as String,
      shortName: json['shortName'] as String,
      power: (json['power'] as num).toDouble(),
      platform: json['platform'] as String,
      txPower: json['txPower'] as int,
      notes: json['notes'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'manufacturer': manufacturer,
      'shortName': shortName,
      'power': power,
      'platform': platform,
      'txPower': txPower,
      'notes': notes,
    };
  }

  @override
  String toString() => 'DeviceModel($shortName, power=$power, txPower=$txPower)';
}

/// Container for the full device models database
class DeviceModelsDatabase {
  final String version;
  final String generated;
  final String source;
  final List<DeviceModel> devices;
  final Map<String, String> powerMapping;
  final List<String> notes;

  const DeviceModelsDatabase({
    required this.version,
    required this.generated,
    required this.source,
    required this.devices,
    required this.powerMapping,
    required this.notes,
  });

  factory DeviceModelsDatabase.fromJson(Map<String, dynamic> json) {
    return DeviceModelsDatabase(
      version: json['version'] as String,
      generated: json['generated'] as String,
      source: json['source'] as String,
      devices: (json['devices'] as List)
          .map((e) => DeviceModel.fromJson(e as Map<String, dynamic>))
          .toList(),
      powerMapping: Map<String, String>.from(json['powerMapping'] as Map),
      notes: List<String>.from(json['notes'] as List),
    );
  }
}
