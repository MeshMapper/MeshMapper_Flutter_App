import AppIntents
import Foundation

/// How the read-only intents decide whether the cached snapshot is recent
/// enough to speak about in the present tense.
///
/// The App Group file deliberately outlives Runner, so every "currently" or
/// "this session" claim has to be checked against `updatedAt` first.
enum MeshMapperSnapshotFreshness {
  static let currentClaimLimit: TimeInterval = 5 * 60

  static func relativeAge(_ age: TimeInterval) -> String {
    let seconds = max(Int(age), 0)
    if seconds < 60 { return "\(seconds) seconds ago" }
    if seconds < 60 * 60 { return "\(seconds / 60) minutes ago" }
    if seconds < 24 * 60 * 60 { return "\(seconds / (60 * 60)) hours ago" }
    return "\(seconds / (24 * 60 * 60)) days ago"
  }
}

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

  /// Nil for `.currentSession`, which is bounded by the session's own start
  /// rather than by a span. Treating that nil as "no boundary" is what made
  /// Current Session silently mean "everything cached"; resolve it against the
  /// snapshot instead.
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
    if age > MeshMapperSnapshotFreshness.currentClaimLimit,
       snapshot.session.active || snapshot.session.starting {
      return .result(
        dialog: "MeshMapper's last session update is too old to report as current. Open the app to refresh it."
      )
    }

    let prefix: String
    if age >= 30 {
      prefix = "As of \(MeshMapperSnapshotFreshness.relativeAge(age)), "
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
    // "Current Session" is a session boundary, not the absence of one. The
    // cached history spans two hours regardless of how many sessions ran in it,
    // so without the session's own start there is nothing to filter against.
    let cutoff: Date
    if timeWindow == .currentSession {
      let age = now.timeIntervalSince(snapshot.updatedAt)
      guard age <= MeshMapperSnapshotFreshness.currentClaimLimit else {
        return .result(
          value: [],
          dialog: "MeshMapper's last update is too old to say what the current session has heard. Open the app to refresh it."
        )
      }
      guard snapshot.session.active || snapshot.session.starting,
            let startedAt = snapshot.session.startedAt
      else {
        return .result(
          value: [],
          dialog: "No MeshMapper mapping session is running."
        )
      }
      cutoff = startedAt
    } else {
      cutoff = timeWindow.duration.map { now.addingTimeInterval(-$0) }
        ?? .distantPast
    }

    var observations = snapshot.recentHeard.filter { $0.observedAt >= cutoff }
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
      let scope = timeWindow == .currentSession
        ? "yet in this session"
        : "in that time window"
      return .result(
        value: [],
        dialog: "MeshMapper hasn't heard any repeaters \(scope)."
      )
    }

    // Naming every result would outstay its welcome when this is heard through
    // AirPods with nothing on screen, but silently dropping the rest would make
    // the spoken answer disagree with the returned value. Say how many are left.
    let spokenCount = min(selected.count, Self.maximumSpokenResults)
    let spoken = selected
      .prefix(spokenCount)
      .map(Self.spokenObservation)
      .joined(separator: ", ")
    let remaining = selected.count - spokenCount
    let lead: String
    if selected.count == 1 {
      lead = "The result was"
    } else if remaining > 0 {
      lead = "The first \(spokenCount) were"
    } else {
      lead = "The results were"
    }
    let tail: String
    switch remaining {
    case 0: tail = ""
    case 1: tail = " There is 1 more result."
    default: tail = " There are \(remaining) more results."
    }
    return .result(value: entities, dialog: "\(lead) \(spoken).\(tail)")
  }

  private static let maximumSpokenResults = 3

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
  // Named for what it can actually search. The App Group catalog holds the
  // active and most recently heard repeaters, not every repeater MeshMapper has
  // loaded, so a broader name would fail unpredictably on the ones it omits.
  static let title: LocalizedStringResource = "Find Recent MeshMapper Repeater"
  static let description = IntentDescription(
    "Looks up one of the active or recently heard repeaters MeshMapper has cached, and says how current that reading is."
  )
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
  static var supportedModes: IntentModes { .background }

  @Parameter(title: "Repeater")
  var repeater: RepeaterEntity

  func perform() async throws -> some IntentResult & ReturnsValue<RepeaterEntity> & ProvidesDialog {
    let snapshot = try? MeshMapperSiriSnapshotStore.shared.read()
    // Prefer the catalog's own record: a saved Shortcut can carry an entity
    // resolved long ago, and its captured state is what would otherwise be
    // spoken as "currently".
    let current = snapshot?.repeaters.first { $0.id == repeater.id }
    let status = (current?.isActive ?? repeater.isActive) ? "active" : "stale"
    let zone = repeater.zoneCode.map { " in \($0)" } ?? ""
    let identity = "\(repeater.name) is repeater \(repeater.hexId)\(zone)"

    // The snapshot deliberately outlives Runner, so it can be days old. Only
    // claim the present tense when it is recent enough to mean anything.
    guard let snapshot else {
      return .result(
        value: repeater,
        dialog: "\(identity). Open MeshMapper to see whether it's still active."
      )
    }
    let age = Date().timeIntervalSince(snapshot.updatedAt)
    guard age <= MeshMapperSnapshotFreshness.currentClaimLimit else {
      return .result(
        value: repeater,
        dialog: "\(identity). When MeshMapper last updated \(MeshMapperSnapshotFreshness.relativeAge(age)), it was \(status)."
      )
    }
    return .result(
      value: repeater,
      dialog: "\(identity), and is currently \(status)."
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
        "Find a recent repeater in \(.applicationName)",
      ],
      shortTitle: "Find Repeater",
      systemImageName: "magnifyingglass"
    )
  }

  static var shortcutTileColor: ShortcutTileColor { .teal }
}
