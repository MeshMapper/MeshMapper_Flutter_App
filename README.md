# MeshMapper Flutter App

> **Note:** All issues and feature requests are tracked in the main project repo: [MeshMapper/MeshMapper_Project](https://github.com/MeshMapper/MeshMapper_Project/issues). Please open issues there rather than in this repository.

Cross-platform wardriving app for [MeshCore](https://github.com/meshcore-dev/MeshCore). Connect to MeshCore companions via Bluetooth, map repeater coverage, and contribute data to the community mesh map.

Built with contributions by **The Greater Ottawa Mesh Radio Enthusiasts**

[View the Map](https://meshmapper.net) | [Wiki](https://wiki.meshmapper.net/) | [Onboard Your Region](https://meshmapper.net/?onboarding) | [Submit Bug/Feature](https://github.com/MeshMapper/MeshMapper_Project/issues)

---

## Get the App

**App Store Releases**
- **Android:** [Google Play](https://play.google.com/store/apps/details?id=net.meshmapper.app) or grab the [APK from GitHub](https://github.com/MeshMapper/MeshMapper_Project/releases/)
- **iOS:** [App Store](https://apps.apple.com/us/app/meshmapper/id6758073991)
- **Web:** [wd.meshmapper.net](https://wd.meshmapper.net) (Chrome/Edge only)

**Beta Releases**
- **iOS:** [TestFlight](https://testflight.apple.com/join/PXxfr5Jr)
- **Android:** [APK from GitHub](https://github.com/MeshMapper/MeshMapper_Project/releases/)

**Quick Start** — Power on your MeshCore Companion, open the app, tap Connect, and select your device via Bluetooth.

---

## Features

- **Cross-Platform** — Android, iOS, and Web (Chrome/Edge)
- **BLE Connectivity** — Connect to MeshCore companion devices via Bluetooth Low Energy
- **GPS Tracking** — High-accuracy location tracking with 50m distance filter
- **Real-time Map** — View TX/RX/DISC ping markers on OpenStreetMap with dark mode tiles
- **Repeater Echo Detection** — 7-second window detects which repeaters echo your pings
- **Passive RX Logging** — Continuously monitors mesh traffic and logs observations
- **Persistent API Queue** — Batch upload with retry logic, survives app restarts
- **Offline Mode** — Wardrive without connectivity, upload data later
- **30+ Device Models** — Automatic identification and power reporting for Ikoka, Heltec, RAK, LilyGo, Seeed, and more
- **Noise Floor Graphing** — Track signal quality over time
- **Dark/Light Theme** — System theme support

---

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions and PR workflow, and [DEVELOPMENT.md](DEVELOPMENT.md) for architecture docs and coding standards.

---

## Architecture

The app uses a service-oriented architecture with platform-specific BLE abstraction:

```
lib/
├── main.dart                    # App entry point, platform detection
├── models/                      # Data models (Hive-annotated)
├── providers/                   # State management (Provider/ChangeNotifier)
├── screens/                     # Full-page UI screens
├── widgets/                     # Reusable components
└── services/
    ├── bluetooth/               # BLE abstraction layer
    │   ├── bluetooth_service.dart   # Abstract interface
    │   ├── mobile_bluetooth.dart    # Android/iOS (flutter_blue_plus)
    │   └── web_bluetooth.dart       # Web (flutter_web_bluetooth)
    ├── meshcore/                # MeshCore protocol layer
    │   ├── connection.dart          # 10-step connection workflow
    │   ├── packet_parser.dart       # Binary packet parsing
    │   ├── unified_rx_handler.dart  # Packet routing (TX vs RX)
    │   ├── tx_tracker.dart          # Repeater echo detection
    │   └── rx_logger.dart           # Passive observation logging
    ├── gps_service.dart         # GPS tracking
    ├── ping_service.dart        # TX/RX ping orchestration
    ├── api_queue_service.dart   # Persistent upload queue
    └── device_model_service.dart # Device identification
```

Key design decisions:
- **Unified RX Handler** — All incoming BLE packets are accepted, parsed once, then routed to TX tracking or RX logging
- **Platform BLE abstraction** — Runtime selection via `kIsWeb` in `main.dart`
- **Hive for persistence** — Local storage for API queue, preferences, and offline sessions
- **Provider for state** — Single `AppStateProvider` with `ChangeNotifier`

See [`DEVELOPMENT.md`](DEVELOPMENT.md) for full details.

---

## Contributing

Contributions are welcome! Please read [CONTRIBUTING.md](CONTRIBUTING.md) before submitting a pull request.

## License

This project is licensed under the MIT License — see [LICENSE](LICENSE) for details.

## Acknowledgments

- Original [MeshMapper WebClient](https://github.com/MeshMapper/MeshMapper_WebClient)
- [MeshCore](https://github.com/meshcore-dev/MeshCore) firmware project
- [The Greater Ottawa Mesh Radio Enthusiasts community](https://ottawamesh.ca/)
