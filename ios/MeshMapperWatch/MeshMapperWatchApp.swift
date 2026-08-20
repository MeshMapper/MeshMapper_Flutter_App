import SwiftUI

/// Entry point for the MeshMapper watchOS companion app.
///
/// The watch is a mirror-and-remote for a session the iPhone owns: the phone
/// holds the BLE link to the MeshCore device and the GPS fix, and pushes
/// snapshots over WatchConnectivity. Nothing here drives a session on its own.
///
/// The app is a vertical pager over a map, a node list, controls, and a debug
/// dump, with wrist-local layout preferences in settings.
@main
struct MeshMapperWatchApp: App {
  @State private var client: WatchSessionClient
  @State private var settings: WatchSettings
  @Environment(\.scenePhase) private var scenePhase

  /// Built here rather than as two independent property initializers so both
  /// the environment and the session client hold the *same* `WatchSettings`.
  /// A second instance would keep its own copy of the haptic preference and
  /// silence only one of them.
  init() {
    let settings = WatchSettings()
    _settings = State(initialValue: settings)
    _client = State(initialValue: WatchSessionClient(settings: settings))
  }

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(client)
        .environment(settings)
        .onAppear { client.refresh() }
        // `onAppear` fires once, and watchOS suspends this app for the whole
        // wrist-down interval, so it cannot speak for a resume. Reconciling
        // here is what stops a glance landing on state the UI calls stale
        // while the phone is available; `resume` decides on its own whether
        // that costs a request.
        .onChange(of: scenePhase) { previous, phase in
          guard phase == .active, previous != .active else { return }
          client.resume()
        }
    }
  }
}
