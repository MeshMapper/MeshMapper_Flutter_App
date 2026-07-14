# iOS Live Activities

MeshMapper starts one read-only Live Activity while an automatic wardriving session or manual ping cycle is active. It mirrors the same state used by the in-app controls.

## Displayed information

- Current mode and phase (`Sending`, `Listening`, `Next ping`, `Cooldown`, GPS/zone/reconnect states)
- System-rendered countdowns based on absolute timer deadlines
- The strongest repeaters from the current or latest completed cycle, sorted by SNR
- TX/RX counters, upload queue, zone, connection state, and stale-update warnings
- Lock Screen, Dynamic Island, and an iOS 18 small-family layout suitable for CarPlay on supported systems

## Architecture

- Dart builds a compact `LiveActivitySnapshot` from `AppStateProvider`.
- `LiveActivityService` deduplicates and throttles noncritical updates before sending them over `meshmapper/live_activity`.
- `LiveActivityManager` creates, updates, deduplicates, and ends the native ActivityKit activity.
- `MeshMapperLiveActivityExtension` renders the snapshot using SwiftUI and WidgetKit.

No push server or App Group is required. The Live Activity does not replace the existing BLE/location background execution; it only presents its state.

## Platform requirements

- Live Activity: iOS 16.2 or later
- Small supplemental activity family: iOS 18 or later
- CarPlay presentation of Live Activities: iOS 26 or later
- A physical iPhone is recommended for final background, Dynamic Island, and CarPlay validation

The main Runner target keeps its existing deployment target. Unsupported devices skip ActivityKit creation.
