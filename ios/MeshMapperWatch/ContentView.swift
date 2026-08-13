import SwiftUI

/// Root shell.
///
/// The map is always page one and full-bleed. Where the heard-node list lives
/// is a presentation choice — a sheet over the map, or its own page — driven by
/// `WatchSettings.nodeListPlacement`. Both read the same `NodeListView`, so
/// this is a toggle rather than two implementations.
struct ContentView: View {
  @Environment(WatchSettings.self) private var settings

  @State private var selection = 0

  var body: some View {
    TabView(selection: $selection) {
      MapPage().tag(0)

      if settings.nodeListPlacement == .page {
        NavigationStack {
          NodeListView()
            .navigationTitle("Heard")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tag(1)
      }

      DebugPage().tag(2)
      SettingsPage().tag(3)
    }
    .tabViewStyle(.verticalPage)
    .onAppear {
      #if DEBUG
      // Lets a specific page be captured headlessly for design review.
      let requested = UserDefaults.standard.integer(forKey: "MeshMapperInitialPage")
      if requested > 0 { selection = requested }
      #endif
    }
  }
}
