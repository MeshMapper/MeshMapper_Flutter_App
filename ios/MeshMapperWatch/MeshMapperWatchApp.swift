import SwiftUI

/// Entry point for the MeshMapper watchOS companion app.
///
/// The watch is a mirror-and-remote for a session the iPhone owns: the phone
/// holds the BLE link to the MeshCore device and the GPS fix, and pushes
/// snapshots over WatchConnectivity. Nothing here drives a session on its own.
///
/// Phase 1 ships the target skeleton only — the WatchConnectivity client, map,
/// node list, and controls arrive in later phases.
@main
struct MeshMapperWatchApp: App {
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
