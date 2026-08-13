import SwiftUI

/// Root shell.
///
/// The map is always page one and full-bleed, with controls immediately after
/// it. Where the heard-node list lives is a presentation choice — a sheet over
/// the map, or its own page — driven by `WatchSettings.nodeListPlacement`.
/// Both read the same `NodeListView`, so this is a toggle rather than two
/// implementations.
struct ContentView: View {
  @Environment(WatchSettings.self) private var settings

  @State private var selection = Self.requestedInitialPage

  /// Page to open on, so one can be captured headlessly for design review —
  /// the simulator offers no way to swipe.
  ///
  /// Supplied as the state's initial value rather than assigned in `onAppear`.
  /// A `.verticalPage` `TabView` ignores a selection change made that late, so
  /// the assignment silently did nothing and every capture landed on the map.
  private static var requestedInitialPage: Int {
    #if DEBUG
    return max(0, UserDefaults.standard.integer(forKey: "MeshMapperInitialPage"))
    #else
    return 0
    #endif
  }

  var body: some View {
    TabView(selection: $selection) {
      MapPage().tag(0)
      ControlsPage().tag(1)

      // The sheet placement is opened by tapping the map's status panel, which
      // the readout does not have — so with Readout selected, honouring "sheet"
      // would leave the heard list with no way in at all. A choice of main page
      // must not make a feature unreachable, so the page appears regardless.
      if settings.nodeListPlacement == .page || settings.mainPageContent == .readout {
        NavigationStack {
          NodeListView()
            .navigationTitle("Heard")
            .navigationBarTitleDisplayMode(.inline)
        }
        .tag(2)
      }

      DebugPage().tag(3)
      SettingsPage().tag(4)
    }
    .tabViewStyle(.verticalPage)
  }
}
