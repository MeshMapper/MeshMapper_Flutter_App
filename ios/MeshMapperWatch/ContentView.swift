import SwiftUI

/// Root shell.
///
/// The map is always page one and full-bleed. Phase 4 adds the node list —
/// either as a sheet over this map or as its own page, per
/// `WatchSettings.nodeListPlacement` — and replaces the debug page.
struct ContentView: View {
  @Environment(WatchSessionClient.self) private var client

  var body: some View {
    TabView {
      MapPage()
      DebugPage()
      SettingsPage()
    }
    .tabViewStyle(.verticalPage)
  }
}
