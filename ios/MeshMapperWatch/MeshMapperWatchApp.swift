import SwiftUI

/// Entry point for the MeshMapper watchOS companion app.
///
/// The watch is a mirror-and-remote for a session the iPhone owns: the phone
/// holds the BLE link to the MeshCore device and the GPS fix, and pushes
/// snapshots over WatchConnectivity. Nothing here drives a session on its own.
///
/// Phase 2 ships the transport and a raw debug dump; the map, node list, and
/// real controls arrive in later phases.
@main
struct MeshMapperWatchApp: App {
  @State private var client = WatchSessionClient()
  @State private var settings = WatchSettings()

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(client)
        .environment(settings)
        .onAppear { client.refresh() }
    }
  }
}
