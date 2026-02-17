# Contributing to MeshMapper Flutter App

Thanks for your interest in contributing to MeshMapper! This document covers everything you need to get started.

## Getting Started

### Prerequisites

- [Flutter SDK](https://flutter.dev/docs/get-started/install) 3.2.0+
- For Android: Android SDK with API 21+
- For iOS: Xcode 14+ with iOS 12+ deployment target
- For Web: Chrome or Edge (Safari not supported — no Web Bluetooth API)

### Building from Source

```bash
git clone https://github.com/MeshMapper/MeshMapper_Flutter_App.git
cd MeshMapper_Flutter_App
flutter pub get
dart run build_runner build --delete-conflicting-outputs
```

### Running Locally

The app requires an API key to communicate with the MeshMapper backend. **API keys are not distributed to external contributors** — the backend is a shared community resource and access is managed by the maintainers.

You can still build, run, and test the app without an API key:

```bash
# Build and run without API key (UI, BLE, GPS, and offline mode all work)
flutter run                        # Android/iOS
flutter run -d chrome              # Web

# Run static analysis
flutter analyze

# Run tests
flutter test
```

Without an API key, the app will function normally for UI work, BLE connectivity, GPS, and offline mode. API calls (zone checks, capacity, wardrive data upload) will fail gracefully. **Maintainers will perform final integration testing with the API before merging.**

### Web Development

For local web development with CORS issues:
```bash
flutter run -d chrome --web-browser-flag="--disable-web-security"
```

Enable debug logging by appending `?debug=1` to the URL.

---

## Submitting Changes

### Branch Strategy

- **`main`** — Stable release branch. Do not target PRs here.
- **`dev`** — Active development branch. **All PRs should target `dev`.**

### Pull Request Workflow

1. **Fork** the repository
2. **Create a feature branch** from `dev`:
   ```bash
   git checkout dev
   git pull origin dev
   git checkout -b feature/your-feature-name
   ```
3. **Make your changes** following the coding standards below
4. **Test your changes**:
   ```bash
   flutter analyze
   flutter test
   ```
5. **Commit** with a clear, descriptive message
6. **Push** your branch and open a PR against `dev`
7. **Describe your changes** in the PR — what, why, and how to test

### PR Guidelines

- Keep PRs focused — one feature or fix per PR
- Include before/after screenshots for UI changes
- If you modified `@HiveType` classes, ensure you ran `dart run build_runner build --delete-conflicting-outputs` and that generated files compile
- Maintainers will perform API integration testing before merging

---

## Coding Standards

### Debug Logging (Required)

All debug log messages **must** include a tag in square brackets:

```dart
debugLog('[BLE] Connection established');
debugLog('[GPS] Position acquired: lat=45.12345');
debugLog('[PING] Sending ping to channel 2');
```

Required tags: `[BLE]`, `[CONN]`, `[GPS]`, `[PING]`, `[API QUEUE]`, `[RX BATCH]`, `[RX]`, `[TX]`, `[DECRYPT]`, `[CRYPTO]`, `[UI]`, `[CHANNEL]`, `[TIMER]`, `[WAKE LOCK]`, `[GEOFENCE]`, `[CAPACITY]`, `[AUTO]`, `[INIT]`, `[MODEL]`, `[MAP]`

See [`docs/DEVELOPMENT_REQUIREMENTS.md`](docs/DEVELOPMENT_REQUIREMENTS.md) for the full list and examples.

### Dart Style

- Use `async`/`await` over `.then()` chains
- Wrap async operations in `try`/`catch` blocks
- Use `debugError()` for logging errors before handling
- Use Dart documentation comments (`///`) for public classes and methods
- State mutations via `AppStateProvider` with `notifyListeners()`

### Platform Considerations

- Use conditional exports for web vs mobile implementations — never import platform-specific files directly
- Test both web and mobile when making cross-platform changes
- `dart:io` is not available on web — use `kIsWeb` checks before platform-specific code

### Hive Models

If you modify any class annotated with `@HiveType`, you must regenerate adapters:

```bash
dart run build_runner build --delete-conflicting-outputs
```

Generated `*.g.dart` files are excluded from version control and regenerated during CI builds.

---

## Documentation

When modifying code, update the relevant documentation:

- **Architecture changes** — Update [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md)
- **Connection workflow changes** — Update [`docs/CONNECTION_WORKFLOW.md`](docs/CONNECTION_WORKFLOW.md)
- **Ping workflow changes** — Update [`docs/PING_WORKFLOW.md`](docs/PING_WORKFLOW.md)
- **Status message changes** — Update [`docs/STATUS_MESSAGES.md`](docs/STATUS_MESSAGES.md)
- **New debug log tags** — Update [`docs/DEVELOPMENT_REQUIREMENTS.md`](docs/DEVELOPMENT_REQUIREMENTS.md)

See [`docs/DEVELOPMENT.md`](docs/DEVELOPMENT.md) for detailed architecture documentation and [`docs/DEVELOPMENT_REQUIREMENTS.md`](docs/DEVELOPMENT_REQUIREMENTS.md) for full coding standards.

---

## Reporting Issues

Use the [MeshMapper Project issue tracker](https://github.com/MeshMapper/MeshMapper_Project/issues) for bugs, feature requests, and questions. Please include:

- App version (shown in Settings)
- Platform (Android/iOS/Web) and OS version
- Steps to reproduce
- Debug logs if applicable (`?debug=1` on web, or logcat/console output on mobile)

---

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
