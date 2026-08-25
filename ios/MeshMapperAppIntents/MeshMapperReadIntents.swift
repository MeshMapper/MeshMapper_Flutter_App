import AppIntents
import Foundation

@available(iOS 26.0, *)
enum RecentHeardWindow: String, AppEnum {
  case lastFiveMinutes
  case lastFifteenMinutes
  case lastHour
  case currentSession

  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Time Window"
  )
  static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .lastFiveMinutes: "Last 5 Minutes",
    .lastFifteenMinutes: "Last 15 Minutes",
    .lastHour: "Last Hour",
    .currentSession: "Current Session",
  ]

  var duration: TimeInterval? {
    switch self {
    case .lastFiveMinutes: return 5 * 60
    case .lastFifteenMinutes: return 15 * 60
    case .lastHour: return 60 * 60
    case .currentSession: return nil
    }
  }
}

@available(iOS 26.0, *)
enum RepeaterSort: String, AppEnum {
  case mostRecent
  case strongest
  case farthest

  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Repeater Sort"
  )
  static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .mostRecent: "Most Recent",
    .strongest: "Strongest",
    .farthest: "Farthest",
  ]
}

@available(iOS 26.0, *)
struct GetMeshMapperStatusIntent: AppIntent {
  static let title: LocalizedStringResource = "Get MeshMapper Status"
  static let description = IntentDescription(
    "Reports the cached connection and mapping-session status without launching MeshMapper."
  )
  static var authenticationPolicy: IntentAuthenticationPolicy {
    .requiresAuthentication
  }
  static var supportedModes: IntentModes { .background }

  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let snapshot = try MeshMapperSiriSnapshotStore.shared.read() else {
      return .result(dialog: "Open MeshMapper once before asking for its status.")
    }

    let age = Date().timeIntervalSince(snapshot.updatedAt)
    if age > 5 * 60, snapshot.session.active || snapshot.session.starting {
      return .result(
        dialog: "MeshMapper's last session update is too old to report as current. Open the app to refresh it."
      )
    }

    let prefix: String
    if age >= 30 {
      prefix = "As of \(Self.relativeAge(age)), "
    } else {
      prefix = ""
    }

    if !snapshot.connection.isConnected {
      return .result(dialog: "\(prefix)MeshMapper wasn't connected to a companion.")
    }
    if snapshot.session.starting {
      return .result(
        dialog: "\(prefix)MeshMapper was starting in \(Self.modeName(snapshot.session.mode)) mode."
      )
    }
    if !snapshot.session.active {
      let device = snapshot.connection.deviceName.map { " to \($0)" } ?? ""
      return .result(
        dialog: "\(prefix)MeshMapper was connected\(device), but no mapping session was running."
      )
    }

    let zone = snapshot.session.zoneCode.map { " in \($0)" } ?? ""
    let detail = snapshot.session.phaseDetail.map { " \($0)." } ?? ""
    return .result(
      dialog: "\(prefix)MeshMapper was running in \(Self.modeName(snapshot.session.mode)) mode\(zone). It had sent \(snapshot.session.txCount) pings and heard \(snapshot.session.uniqueRepeatersHeard) unique repeaters. \(snapshot.session.phaseTitle).\(detail)"
    )
  }

  private static func modeName(_ mode: String) -> String {
    mode == "passive" ? "Passive Discovery" : mode.capitalized
  }

  private static func relativeAge(_ age: TimeInterval) -> String {
    let seconds = max(Int(age), 0)
    if seconds < 60 { return "\(seconds) seconds ago" }
    if seconds < 60 * 60 { return "\(seconds / 60) minutes ago" }
    if seconds < 24 * 60 * 60 { return "\(seconds / (60 * 60)) hours ago" }
    return "\(seconds / (24 * 60 * 60)) days ago"
  }
}

@available(iOS 26.0, *)
struct GetRecentlyHeardRepeatersIntent: AppIntent {
  static let title: LocalizedStringResource = "Get Recently Heard Repeaters"
  static let description = IntentDescription(
    "Returns recent MeshMapper repeater observations from a bounded local cache."
  )
  static var authenticationPolicy: IntentAuthenticationPolicy {
    .requiresAuthentication
  }
  static var supportedModes: IntentModes { .background }

  @Parameter(title: "Within", default: .lastFifteenMinutes)
  var timeWindow: RecentHeardWindow

  @Parameter(title: "Sort By", default: .mostRecent)
  var sort: RepeaterSort

  @Parameter(title: "Maximum Results", default: 3, inclusiveRange: (1, 5))
  var limit: Int

  func perform() async throws -> some IntentResult & ReturnsValue<[HeardRepeaterEntity]> & ProvidesDialog {
    guard let snapshot = try MeshMapperSiriSnapshotStore.shared.read() else {
      return .result(
        value: [],
        dialog: "Open MeshMapper once before asking what it heard."
      )
    }

    let now = Date()
    var observations = snapshot.recentHeard.filter { observation in
      guard let duration = timeWindow.duration else { return true }
      return now.timeIntervalSince(observation.observedAt) <= duration
    }
    switch sort {
    case .mostRecent:
      observations.sort { $0.observedAtMs > $1.observedAtMs }
    case .strongest:
      observations.sort { ($0.snr ?? -.infinity) > ($1.snr ?? -.infinity) }
    case .farthest:
      observations.sort {
        ($0.distanceM ?? -.infinity) > ($1.distanceM ?? -.infinity)
      }
    }

    // The parameter range guides Siri/Shortcuts, while the clamp preserves
    // safety for an older saved Shortcut carrying an out-of-range value.
    let requestedLimit = min(max(limit, 1), 5)
    let selected = Array(observations.prefix(requestedLimit))
    let repeaterById = Dictionary(
      snapshot.repeaters.map { ($0.id, $0) },
      uniquingKeysWith: { existing, _ in existing }
    )
    let entities = selected.map {
      HeardRepeaterEntity(observation: $0, repeaterById: repeaterById)
    }
    guard !selected.isEmpty else {
      return .result(
        value: [],
        dialog: "MeshMapper didn't hear any repeaters in that time window."
      )
    }

    let spoken = selected.prefix(3).map(Self.spokenObservation).joined(separator: ", ")
    let lead = selected.count == 1 ? "The result was" : "The results were"
    return .result(value: entities, dialog: "\(lead) \(spoken).")
  }

  private static func spokenObservation(_ observation: MeshMapperSiriObservation) -> String {
    let identity = observation.name ?? "repeater \(observation.displayHexId)"
    let signal = observation.snr.map { String(format: " at %.1f dB", $0) } ?? ""
    let distance: String
    if let meters = observation.distanceM {
      distance = meters >= 1_000
        ? String(format: ", about %.1f kilometers away", meters / 1_000)
        : String(format: ", about %.0f meters away", meters)
    } else {
      distance = ""
    }
    return "\(identity)\(signal)\(distance)"
  }
}

@available(iOS 26.0, *)
struct FindMeshMapperRepeaterIntent: AppIntent {
  static let title: LocalizedStringResource = "Find MeshMapper Repeater"
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
  static var supportedModes: IntentModes { .background }

  @Parameter(title: "Repeater")
  var repeater: RepeaterEntity

  func perform() async throws -> some IntentResult & ReturnsValue<RepeaterEntity> & ProvidesDialog {
    let status = repeater.isActive ? "active" : "stale"
    let zone = repeater.zoneCode.map { " in \($0)" } ?? ""
    return .result(
      value: repeater,
      dialog: "\(repeater.name) is repeater \(repeater.hexId)\(zone), and is currently \(status)."
    )
  }
}

@available(iOS 26.0, *)
struct MeshMapperReadAppShortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
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
    AppShortcut(
      intent: FindMeshMapperRepeaterIntent(),
      phrases: [
        "Find a repeater in \(.applicationName)",
      ],
      shortTitle: "Find Repeater",
      systemImageName: "magnifyingglass"
    )
  }

  static var shortcutTileColor: ShortcutTileColor { .teal }
}
