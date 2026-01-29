# MeshMapper Flutter App - Architecture

This document describes the architecture of the MeshMapper Flutter app, which is a port of the MeshMapper WebClient to Flutter for cross-platform support (Android, iOS, Web).

## Overview

The app is structured following Flutter best practices with clear separation between:
- **Models**: Data structures and types
- **Services**: Business logic and platform interactions
- **Providers**: State management
- **Screens**: Full-page UI components
- **Widgets**: Reusable UI components

## Directory Structure

```
lib/
├── main.dart                           # App entry point
├── models/
│   ├── device_model.dart               # Device model database types
│   ├── ping_data.dart                  # TX/RX ping data types
│   ├── connection_state.dart           # Connection enums and states
│   └── api_queue_item.dart             # Persistent queue item
├── services/
│   ├── bluetooth/
│   │   ├── bluetooth_service.dart      # Abstract BLE interface
│   │   ├── mobile_bluetooth.dart       # Android/iOS implementation
│   │   └── web_bluetooth.dart          # Web Bluetooth API implementation
│   ├── meshcore/
│   │   ├── connection.dart             # MeshCore protocol handler
│   │   ├── packet_parser.dart          # Binary packet parsing
│   │   ├── buffer_utils.dart           # Buffer read/write utilities
│   │   └── protocol_constants.dart     # Protocol constants
│   ├── gps_service.dart                # GPS tracking and geofencing
│   ├── api_service.dart                # HTTP API client
│   ├── api_queue_service.dart          # Persistent upload queue
│   ├── device_model_service.dart       # Device database and model identification
│   └── ping_service.dart               # TX/RX orchestration
├── providers/
│   └── app_state_provider.dart         # Main app state
├── screens/
│   ├── home_screen.dart                # Main wardriving UI
│   ├── connection_screen.dart          # Device connection
│   └── settings_screen.dart            # App settings
└── widgets/
    ├── map_widget.dart                 # Map with markers
    ├── connection_panel.dart           # Connection status
    ├── ping_controls.dart              # Ping buttons
    ├── status_bar.dart                 # GPS/connection status
    └── stats_panel.dart                # Statistics display
```

## Key Components

### 1. Bluetooth Service Abstraction

The `BluetoothService` abstract class provides a platform-agnostic interface:

```dart
abstract class BluetoothService {
  Stream<ConnectionStatus> get connectionStream;
  Stream<Uint8List> get dataStream;
  Future<void> connect(String deviceId);
  Future<void> write(Uint8List data);
}
```

Platform implementations:
- `MobileBluetoothService`: Uses `flutter_blue_plus` for Android/iOS
- `WebBluetoothService`: Uses `flutter_web_bluetooth` for Chrome/Edge

### 2. MeshCore Connection

The `MeshCoreConnection` class handles the 10-step connection workflow:

1. BLE GATT Connect
2. Protocol Handshake
3. Device Info Query
4. Device Identification (for display/reporting only - does NOT modify radio settings)
5. Time Sync
6. API Slot Acquisition
7. Channel Setup
8. GPS Init
9. Connected State

### 3. GPS Service

The `GpsService` provides:
- High-accuracy position tracking
- Geofence validation (150km from Ottawa)
- 25m movement threshold for pings

### 4. Ping Service

The `PingService` orchestrates TX/RX flows:

**TX Flow:**
1. Validate conditions (GPS lock, geofence, distance)
2. Send ping via BLE
3. Start 6-second RX listening window
4. Queue for API upload

**RX Flow:**
1. Listen for repeater echoes during window
2. Buffer by repeater ID (max 4 per repeater)
3. Flush to API queue when window ends

### 5. API Queue Service

The `ApiQueueService` provides:
- Hive-based persistent storage
- Batch uploads (10 items or 30 seconds)
- Exponential backoff retry

## State Management

Uses Provider pattern with `ChangeNotifier`:

```dart
class AppStateProvider extends ChangeNotifier {
  // Connection state
  ConnectionStatus get connectionStatus;
  ConnectionStep get connectionStep;
  
  // GPS state
  GpsStatus get gpsStatus;
  Position? get currentPosition;
  
  // Ping state
  PingStats get pingStats;
  bool get autoPingEnabled;
}
```

## Platform-Specific Handling

### Android
- Requires Bluetooth and Location permissions
- minSdkVersion: 21
- Background location for continuous tracking

### iOS
- Requires Bluetooth and Location usage descriptions
- deployment target: 12.0
- Background modes: bluetooth-central, location

### Web
- Requires Chrome/Edge (Safari not supported)
- Web Bluetooth API with service worker

## Critical Protocol Details

### BLE Service UUIDs
- Service: `6E400001-B5A3-F393-E0A9-E50E24DCCA9E`
- RX Characteristic: `6E400002-B5A3-F393-E0A9-E50E24DCCA9E`
- TX Characteristic: `6E400003-B5A3-F393-E0A9-E50E24DCCA9E`

### Power Level Reporting
The app identifies device models to determine what power level to report in API calls:
- 33dBm models: 2.0W
- 30dBm models: 1.0W
- Standard (22dBm): 0.3W

**Important**: The app does NOT modify the radio's TX power settings. It only reads device information and reports the appropriate power level to the API. Users configure their radio's actual TX power through the device firmware.

## Dependencies

- `flutter_blue_plus`: Mobile Bluetooth
- `flutter_web_bluetooth`: Web Bluetooth
- `geolocator`: GPS/Location
- `flutter_map`: Map rendering
- `hive`: Local storage
- `provider`: State management
- `http`: API requests
- `pointycastle`: Encryption
