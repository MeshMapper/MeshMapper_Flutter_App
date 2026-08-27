import AppIntents

/// The app's single `AppShortcutsProvider`.
///
/// Both the provider and every intent it names must be members of the app
/// target — an `AppShortcutsProvider` inside the App Intents extension is never
/// indexed, so its phrases silently do nothing when spoken. The read intents
/// are therefore compiled into Runner as well as the extension, which is
/// Apple's documented arrangement for an intent that backs an App Shortcut and
/// must also run in an extension. Keep the count at or below ten; exceeding it
/// is a compile error.
@available(iOS 26.0, *)
struct MeshMapperAppShortcuts: AppShortcutsProvider {
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
    AppShortcut(
      intent: GetMeshMapperStatusIntent(),
      phrases: [
        "What is \(.applicationName) doing",
        "Get \(.applicationName) status",
      ],
      shortTitle: "Session Status",
      systemImageName: "waveform"
    )
    AppShortcut(
      intent: GetRecentlyHeardRepeatersIntent(),
      phrases: [
        "What has \(.applicationName) heard",
        "Recent repeaters in \(.applicationName)",
      ],
      shortTitle: "Recent Repeaters",
      systemImageName: "dot.radiowaves.left.and.right"
    )
    // TODO: Re-register FindMeshMapperRepeaterIntent once spoken repeater
    // lookup works. The intent, RepeaterEntity and RepeaterEntityQuery are all
    // still built and shipped — only the spoken phrase is withdrawn, because a
    // registered phrase that fails is worse than one that was never offered.
    // Restore the AppShortcut here, and its bullet in DEVELOPMENT.md's phrase
    // list, in the same change.
  }

  static var shortcutTileColor: ShortcutTileColor { .teal }
}
