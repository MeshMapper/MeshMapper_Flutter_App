import 'connection_state.dart';

/// Remembered device for quick reconnection.
/// Supports BLE, TCP, and USB Serial transports.
class RememberedDevice {
  final String id;
  final String name;
  final DateTime lastConnected;
  final TransportType transportType;
  final String? tcpHost;
  final int? tcpPort;
  final String? serialPortPath;

  const RememberedDevice({
    required this.id,
    required this.name,
    required this.lastConnected,
    this.transportType = TransportType.ble,
    this.tcpHost,
    this.tcpPort,
    this.serialPortPath,
  });

  factory RememberedDevice.fromJson(Map<String, dynamic> json) {
    return RememberedDevice(
      id: json['id'] as String,
      name: json['name'] as String,
      lastConnected: DateTime.parse(json['lastConnected'] as String),
      transportType: _parseTransportType(json['transportType'] as String?),
      tcpHost: json['tcpHost'] as String?,
      tcpPort: json['tcpPort'] as int?,
      serialPortPath: json['serialPortPath'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'lastConnected': lastConnected.toIso8601String(),
      'transportType': transportType.name,
      if (tcpHost != null) 'tcpHost': tcpHost,
      if (tcpPort != null) 'tcpPort': tcpPort,
      if (serialPortPath != null) 'serialPortPath': serialPortPath,
    };
  }

  String get displayName => name.replaceFirst('MeshCore-', '');

  static TransportType _parseTransportType(String? value) {
    if (value == null) return TransportType.ble;
    return TransportType.values.firstWhere(
      (e) => e.name == value,
      orElse: () => TransportType.ble,
    );
  }
}
