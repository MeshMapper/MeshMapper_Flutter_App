# iOS Live Activities

MeshMapper starts one read-only Live Activity while an automatic wardriving session or manual ping cycle is active. It mirrors the same state used by the in-app controls.

## Displayed information

- Current mode and phase (`Sending`, `Listening`, `Next ping`, `Cooldown`, GPS/zone/reconnect states)
- System-rendered countdowns based on absolute timer deadlines
- The map's Top Heard rows: the latest ping's top three repeaters by SNR plus the current passive RX slot, the same list the watch shows. Rows heard before the latest send stay on the card dimmed as last heard; a silent ping does not wipe them
- TX/RX counters, upload queue, zone, connection state, and stale-update warnings
- Lock Screen, Dynamic Island, and one iOS 18 small-family layout shared by the paired watch's Smart Stack card and the CarPlay dashboard. CarPlay's canvas overlaps the watch card sizes and nothing names the surface, so the card solves its row count and font from the measured height instead of guessing

## Architecture

- Dart builds a compact `LiveActivitySnapshot` from `AppStateProvider`.
- `LiveActivityService` deduplicates and throttles noncritical updates before sending them over `meshmapper/live_activity`.
- `LiveActivityManager` creates, updates, deduplicates, and ends the native ActivityKit activity.
- `MeshMapperLiveActivityExtension` renders the snapshot using SwiftUI and WidgetKit.

No push server or App Group is required. The Live Activity does not replace the existing BLE/location background execution; it only presents its state.

## Platform requirements

- Live Activity: iOS 16.2 or later
- Small supplemental activity family (watch Smart Stack, CarPlay dashboard): iOS 18 or later
- CarPlay presentation of Live Activities: iOS 26 or later
- A physical iPhone is recommended for final background, Dynamic Island, and CarPlay validation; the Smart Stack card needs a paired watch

The main Runner target keeps its existing deployment target. Unsupported devices skip ActivityKit creation.
