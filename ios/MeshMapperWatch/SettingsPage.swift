import SwiftUI

/// Wrist-side layout and map preferences.
///
/// Deliberately small. Anything about the session itself belongs on the phone,
/// which owns the radio and the guards.
struct SettingsPage: View {
  @Environment(WatchSettings.self) private var settings
  @Environment(WatchSessionClient.self) private var client

  private var availableStartModes: [WatchSettings.DefaultStartMode] {
    let available = client.snapshot?.availableStartModes ?? ["passive"]
    return WatchSettings.DefaultStartMode.allCases.filter {
      $0 == .passive || available.contains($0.rawValue)
    }
  }

  private var effectiveStartMode: WatchSettings.DefaultStartMode {
    settings.effectiveStartMode(
      availableStartModes: client.snapshot?.availableStartModes
    )
  }

  var body: some View {
    @Bindable var settings = settings

    List {
      Section("Display") {
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

      Section("Map") {
        Toggle("Follow position", isOn: $settings.follow)
        Toggle("Lines to repeaters", isOn: $settings.showLinks)
      }

      Section("Controls") {
        Picker(
          "Default start mode",
          selection: Binding(
            get: { effectiveStartMode },
            set: { settings.defaultStartMode = $0 }
          )
        ) {
          ForEach(availableStartModes) { mode in
            Text(mode.label).tag(mode)
          }
        }

        if settings.defaultStartMode != effectiveStartMode {
          Text("Hybrid unavailable here; Start uses Passive")
            .foregroundStyle(WatchPalette.tertiary)
        }

        Toggle(
          "When available, show ping option",
          isOn: $settings.showPingWhenAvailable
        )
      }
    }
    .font(.caption)
  }
}
