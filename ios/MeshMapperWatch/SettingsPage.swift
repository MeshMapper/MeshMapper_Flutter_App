import SwiftUI

/// Wrist-side layout and map preferences.
///
/// Deliberately small. Anything about the session itself belongs on the phone,
/// which owns the radio and the guards.
struct SettingsPage: View {
  @Environment(WatchSettings.self) private var settings

  var body: some View {
    @Bindable var settings = settings

    List {
      Section("Map") {
        Toggle("Satellite", isOn: $settings.satellite)
        Toggle("Follow position", isOn: $settings.follow)
        Toggle("Lines to repeaters", isOn: $settings.showLinks)
      }

      Section("Layout") {
        Picker("Main page", selection: $settings.mainPageContent) {
          ForEach(WatchSettings.MainPageContent.allCases) { content in
            Text(content.label).tag(content)
          }
        }
        Picker("Node list", selection: $settings.nodeListPlacement) {
          ForEach(WatchSettings.NodeListPlacement.allCases) { placement in
            Text(placement.label).tag(placement)
          }
        }
      }
    }
    .font(.caption)
  }
}
