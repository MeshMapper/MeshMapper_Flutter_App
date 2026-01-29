# MeshMapper Flutter App - Development Guidelines

## Overview
This document defines the coding standards and requirements for all changes to the MeshMapper Flutter App repository. AI agents and contributors must follow these guidelines for every modification.

---

## Code Style & Standards

### Debug Logging
- **ALWAYS** include debug console logging for significant operations
- Use the existing debug helper functions (from `utils/debug_logger_io.dart`):
  - `debugLog(message, ...args)` - For general debug information
  - `debugWarn(message, ...args)` - For warning conditions
  - `debugError(message, ...args)` - For error conditions
- Debug logging is controlled by the `DEBUG_ENABLED` flag (URL parameter `?debug=1` for web builds)
- Log at key points: function entry, API calls, state changes, errors, and decision branches

#### Debug Log Tagging Convention

All debug log messages **MUST** include a descriptive tag in square brackets at the start that identifies the subsystem or feature area. This enables easier filtering and understanding of debug output.

**Format:** `[TAG] Message here`

**Required Tags:**

| Tag | Description |
|-----|-------------|
| `[BLE]` | Bluetooth connection and device communication |
| `[CONN]` | MeshCore connection protocol operations |
| `[GPS]` | GPS/geolocation operations |
| `[PING]` | Ping sending and validation |
| `[API QUEUE]` | API queue operations (batch posting) |
| `[RX BATCH]` | RX batch buffer operations |
| `[RX]` | RX packet handling and logging |
| `[TX]` | TX packet handling and logging |
| `[DECRYPT]` | Message decryption |
| `[CRYPTO]` | Cryptographic operations (SHA-256, AES) |
| `[UI]` | General UI updates (status bar, buttons, etc.) |
| `[CHANNEL]` | Channel setup and management |
| `[TIMER]` | Timer and countdown operations |
| `[WAKE LOCK]` | Wake lock acquisition/release |
| `[GEOFENCE]` | Geofence and distance validation |
| `[CAPACITY]` | Capacity check API calls |
| `[AUTO]` | Auto mode operations (TX/RX or RX-only) |
| `[INIT]` | Initialization and setup |
| `[AUTH]` | Authentication API operations |
| `[HEARTBEAT]` | Session heartbeat operations |
| `[API]` | General API operations |
| `[MODEL]` | Device model identification and power reporting |
| `[MAP]` | Map widget operations |

**Examples:**
```dart
// ✅ Correct - includes tag
debugLog("[BLE] Connection established");
debugLog("[GPS] Fresh position acquired: lat=45.12345, lon=-75.12345");
debugLog("[PING] Sending ping to channel 2");
debugLog("[CONN] Creating #wardriving channel");

// ❌ Incorrect - missing tag
debugLog("Connection established");
debugLog("Fresh position acquired");
```

### Status Messages
- **ALWAYS** update `STATUS_MESSAGES.md` when adding or modifying user-facing status messages
- Use the status update methods in `AppStateProvider` for all UI status updates
- Use appropriate status types:
  - `idle` - Default/waiting state
  - `success` - Successful operations
  - `warning` - Warning conditions
  - `error` - Error states
  - `info` - Informational/in-progress states

---

## Documentation Requirements

### Code Comments
- Document complex logic with inline comments
- Use Dart documentation comments (`///`) for public classes and methods
- Include:
  - Brief description of purpose
  - Parameter descriptions where not obvious
  - Return value descriptions
  - Throws clauses for exceptions

### docs/STATUS_MESSAGES.md Updates
When adding new status messages, include:
- The exact status message text
- When it appears (trigger condition)
- The status type used
- Any follow-up actions or states

### docs/CONNECTION_WORKFLOW.md Updates
When **modifying connect or disconnect logic**, you must:
- Read `docs/CONNECTION_WORKFLOW.md` before making the change (to understand current intended behavior)
- Update `docs/CONNECTION_WORKFLOW.md` so it remains accurate after the change:
  - Steps/sequence of the workflow
  - Any new states, retries, timeouts, or error handling
  - Any UI impacts (buttons, indicators, status messages)

### docs/PING_WORKFLOW.md Updates
When **modifying ping or auto-ping logic**, you must:
- Read `docs/PING_WORKFLOW.md` before making the change (to understand current intended behavior)
- Update `docs/PING_WORKFLOW.md` so it remains accurate after the change:
  - Ping flows (manual ping, auto-ping lifecycle)
  - Validation logic (geofence, distance, cooldown)
  - GPS acquisition and payload construction
  - Repeater tracking and MeshMapper API posting
  - Control locking and cooldown management
  - Auto mode behavior (intervals, wake lock, page visibility)
  - Any UI impacts (buttons, status messages, countdown displays)

---

## Flutter/Dart Specific Guidelines

### State Management
- Use `ChangeNotifier` pattern via `AppStateProvider` for global state
- Use `notifyListeners()` after state mutations to trigger UI updates
- Avoid direct widget state manipulation - use providers

### Async/Await
- Prefer `async`/`await` over `.then()` chains for readability
- Always wrap async operations in `try`/`catch` blocks
- Log errors with `debugError()` before rethrowing or handling

### Platform Differences
- Use conditional exports for web vs mobile implementations:
  - `debug_logger_io.dart` for the public API
  - `debug_logger.dart` for web (uses package:web)
  - `debug_logger_stub.dart` for mobile (uses debugPrint)
- Test both web and mobile builds when making cross-platform changes

### Error Handling
- Catch specific exceptions where possible
- Provide user-friendly error messages in the UI
- Log detailed error information with `debugError()` for debugging
- Don't let exceptions crash the app - handle gracefully

---

## Testing & Validation

### Before Committing
1. Run `flutter analyze` to check for issues
2. Build for web: `flutter build web --release`
3. Test critical workflows manually:
   - Connection/disconnection
   - Ping sending (if applicable)
   - Auto-ping modes (if applicable)
4. Verify debug logging works with `?debug=1`
5. Check that status messages appear correctly

### Documentation Checklist
- [ ] Added debug logging with tags to new code
- [ ] Updated STATUS_MESSAGES.md if status text changed
- [ ] Updated CONNECTION_WORKFLOW.md if connection logic changed
- [ ] Updated PING_WORKFLOW.md if ping logic changed
- [ ] Added inline comments for complex logic
- [ ] Added Dart doc comments (`///`) for public APIs

---

## Architecture Alignment

This Flutter app is a port of the MeshMapper WebClient. When implementing features:
1. Reference the original JavaScript implementation in `MeshMapper_WebClient/content/wardrive.js`
2. Follow the same architectural patterns (connection workflow, API queue, etc.)
3. Maintain feature parity where possible
4. Document any intentional deviations in `docs/PORTING_NOTES.md`

---

### Requested Change

<< Requested Changes go here >>
