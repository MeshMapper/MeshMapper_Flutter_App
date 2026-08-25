import AppIntents

@available(iOS 26.0, *)
struct MeshMapperMutationAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: ConnectLastMeshMapperCompanionIntent(),
      phrases: [
        "Connect \(.applicationName) to its last companion",
        "Reconnect \(.applicationName)",
        "Connect \(.applicationName)",
        "Connect \(.applicationName) to the last device",
        "Connect to the last device in \(.applicationName)",
        "Reconnect the last device in \(.applicationName)",
      ],
      shortTitle: "Connect Companion",
      systemImageName: "link"
    )
    AppShortcut(
      intent: StartMeshMapperSessionIntent(),
      phrases: [
        "Start \(.applicationName)",
        "Start a session in \(.applicationName)",
        "Start mapping with \(.applicationName)",
        "Start \(\.$mode) in \(.applicationName)",
        "Start \(\.$mode) mode in \(.applicationName)",
        "Start a \(\.$mode) session in \(.applicationName)",
        "Start \(.applicationName) in \(\.$mode) mode",
        "Start \(\.$mode) mapping with \(.applicationName)",
      ],
      shortTitle: "Start Session",
      systemImageName: "antenna.radiowaves.left.and.right"
    )
    AppShortcut(
      intent: StopMeshMapperSessionIntent(),
      phrases: [
        "Stop \(.applicationName)",
        "Stop the session in \(.applicationName)",
        "Stop mapping with \(.applicationName)",
        "End the session in \(.applicationName)",
      ],
      shortTitle: "Stop Session",
      systemImageName: "stop.fill"
    )
  }

  static var shortcutTileColor: ShortcutTileColor { .teal }
}
