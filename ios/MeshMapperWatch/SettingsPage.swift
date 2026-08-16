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

        // Sits with Controls because the only cue the phone sends is the
        // failure of a control the wearer used. It is the wearer's own wrist,
        // so the switch stays on the wrist: silencing it must not depend on
        // the phone link that just failed.
        Toggle("Haptic feedback", isOn: $settings.haptics)
      }

      #if DEBUG
      // Not a preference — an A/B switch for an Instruments trace, so it never
      // reaches Release. Takes effect from the next phase rather than mid-drain.
      Section("Instruments") {
        Toggle("Freeze timer bar", isOn: $settings.freezesTimerBar)
        // Persisted, unlike the launch argument this replaced — a wrist-down
        // test invites watchOS to relaunch the app, which silently emptied
        // `NSArgumentDomain` and produced an empty log with no clue why.
        Toggle("Log wake timing", isOn: $settings.logsWakeTiming)
      }
      #endif
    }
    .font(.caption)
  }
}
