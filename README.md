# MeshMapper Flutter App

Cross-platform wardriving app for MeshCore devices. A Flutter port of the [MeshMapper WebClient](https://github.com/MeshMapper/MeshMapper_WebClient).

## Features

- **Cross-Platform**: Runs on Android, iOS, and Web (Chrome/Edge)
- **BLE Connectivity**: Connect to MeshCore devices via Bluetooth Low Energy
- **GPS Tracking**: High-accuracy location tracking with 25m distance filter
- **Geofencing**: Enforces 150km boundary from Ottawa (service area)
- **Auto-Power Selection**: Automatically configures TX power based on device model
- **Real-time Map**: View TX/RX ping markers on OpenStreetMap
- **API Queue**: Persistent queue with batch upload and retry logic
- **Dark Mode**: System theme support

## Screenshots

*Coming soon*

## Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) 3.2.0 or higher
- For Android: Android SDK with API 21+
- For iOS: Xcode 14+ and iOS 12+ deployment target
- For Web: Chrome or Edge browser (Safari not supported for Web Bluetooth)

### Installation

1. Clone the repository:
```bash
git clone https://github.com/MeshMapper/MeshMapper_Flutter_App.git
cd MeshMapper_Flutter_App
```

2. Install dependencies:
```bash
flutter pub get
```

3. Run the app:
```bash
# For Android/iOS
flutter run

# For Web
flutter run -d chrome
```

## Project Structure

```
lib/
├── main.dart                    # App entry point
├── models/                      # Data models
├── services/                    # Business logic
│   ├── bluetooth/               # BLE abstractions
│   ├── meshcore/                # MeshCore protocol
│   └── ...                      # GPS, API, etc.
├── providers/                   # State management
├── screens/                     # Full-page UI
└── widgets/                     # Reusable components

assets/
└── device-models.json           # Device database

docs/
├── ARCHITECTURE.md              # System design
└── PORTING_NOTES.md             # JS→Dart translation
```

## Supported Devices

The app supports 30+ MeshCore device variants including:

- **Ikoka**: Stick, Nano, Handheld (22dBm, 30dBm, 33dBm variants)
- **Heltec**: V2, V3, V4, T114, T190, E213, E290, MeshPocket
- **RAK**: 4631, 3x72
- **LilyGo**: T-Echo, T-Deck, T-Beam, T-LoRa
- **Seeed**: Wio E5, Wio Tracker, T1000, Xiao variants
- And more...

See `assets/device-models.json` for the full list.

## Usage

### Connecting to a Device

1. Tap the Bluetooth icon in the app bar
2. Tap "Scan" to search for nearby MeshCore devices
3. Select your device from the list
4. The app will automatically:
   - Connect via BLE
   - Query device info
   - Configure TX power based on device model
   - Sync time
   - Acquire API slot

### Wardriving

1. Ensure GPS is enabled and permissions granted
2. Wait for GPS lock (green GPS indicator)
3. Tap the "PING" button to send a TX ping
4. Or enable "Auto Ping" to automatically ping every 25m of movement

### Understanding the Map

- **Green markers**: Your TX pings
- **Colored markers**: RX responses from repeaters (color by repeater ID)
- **Blue circle**: Your current position

## Critical Safety Notes

⚠️ **PA Amplifier Devices**: The app automatically configures TX power for high-power PA amplifier devices. Do NOT manually override power settings as incorrect values can damage hardware.

⚠️ **Geofence**: Pings are only allowed within 150km of Ottawa. This is enforced both client-side and server-side.

## Development

### Running Tests

```bash
flutter test
```

### Building for Release

```bash
# Android
flutter build apk --release

# iOS
flutter build ios --release

# Web
flutter build web --release
```

## Architecture

The app follows a service-oriented architecture:

- **BluetoothService**: Abstract interface with platform-specific implementations
- **MeshCoreConnection**: Handles the 10-step connection workflow and protocol
- **GpsService**: GPS tracking with geofence validation
- **PingService**: TX/RX ping orchestration
- **ApiQueueService**: Persistent upload queue with retry logic

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for details.

## Contributing

Contributions are welcome! Please read the [PORTING_NOTES.md](docs/PORTING_NOTES.md) for guidance on the JavaScript to Dart translation patterns used.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Original [MeshMapper WebClient](https://github.com/MeshMapper/MeshMapper_WebClient)
- [MeshCore](https://github.com/meshcore-dev/MeshCore) firmware project
- Flutter and Dart teams