import Foundation

/// Wire contract between the iPhone app and the watchOS companion.
///
/// Shared source: this file is compiled into both Runner and MeshMapperWatch,
/// so the two can never drift. Dart builds the equivalent JSON in
/// `lib/services/watch/watch_models.dart`; the golden fixtures in
/// `test/services/watch/` are what keep Dart and Swift honest with each other.
///
/// Design notes that matter for battery and correctness:
///
/// - **Countdowns are absolute deadlines** (`phaseEndsAt`), never tick counts.
///   The watch renders them with `Text(timerInterval:)`, so an active session
///   sends roughly one update per phase transition rather than one per second.
/// - **Colours are resolved on the phone.** Dart owns the colour-vision
///   palettes, so the watch receives sRGB components and stays dumb. This is
///   why accessibility palettes work on the wrist for free.
/// - **Everything is capped.** WatchConnectivity payloads should stay small;
///   the wrist is a glance surface and the phone is where the full history is.
enum MeshMapperWatchWire {
  /// Bump when a field changes meaning or is removed. The receiver refuses
  /// payloads it doesn't understand rather than rendering something wrong.
  ///
  /// v2: heard nodes mirror the app's "Top Heard" map overlay — hex ID and
  /// ping-type colour — instead of richer per-echo data. Hop counts are gone:
  /// the overlay is fed direct repeaters only.
  static let version = 2

  /// Caps, mirrored in Dart. Enforced on send *and* validated on receive.
  static let maxPings = 60
  static let maxRepeaters = 20

  /// Three top-SNR rows plus the RX slot.
  static let maxHeard = 4
}

// MARK: - Colour

/// An sRGB colour resolved by Dart from the active colour-vision palette.
struct WatchColor: Codable, Hashable {
  let r: Double
  let g: Double
  let b: Double
}

// MARK: - Geo

struct WatchPosition: Codable, Hashable {
  let lat: Double
  let lon: Double
  /// Degrees clockwise from true north; nil when the fix has no course.
  let headingDeg: Double?
  let accuracyM: Double?
  /// Milliseconds since epoch, so the watch can age the fix itself.
  let fixedAtMs: Double
}

/// A ping marker, already coloured by outcome.
struct WatchPing: Codable, Hashable, Identifiable {
  let id: String
  let lat: Double
  let lon: Double
  /// "tx" | "rx" | "disc" | "trace" — for glyph choice, not colour.
  let kind: String
  let color: WatchColor
  let atMs: Double
}

/// A repeater pin. `heardThisCycle` drives the highlight ring.
struct WatchRepeater: Codable, Hashable, Identifiable {
  let id: String
  let name: String
  let lat: Double
  let lon: Double
  let color: WatchColor
  let heardThisCycle: Bool
}

/// One row of the "Top Heard" overlay.
///
/// Mirrors `_buildTopRepeatersOverlay` on the phone's map: a dot coloured by
/// the kind of ping answered, the hex path-hash ID, and the SNR.
///
/// The **hex ID is the identity**. Path hashes are 1–3 bytes, so a short ID
/// often maps to more than one repeater; `name` arrives only when the match is
/// unambiguous and is shown as a secondary hint, never in place of the ID.
///
/// No hop count by design — the overlay is fed direct repeaters only.
struct WatchHeardNode: Codable, Hashable, Identifiable {
  /// Uppercase hex, 2/4/6 characters depending on the zone's hop bytes.
  let id: String
  let name: String?
  let snr: Double?
  let atMs: Double
  let distanceM: Double?
  /// SNR traffic-light colour, resolved by Dart.
  let snrColor: WatchColor?
  /// Ping type answered: green flood/active, teal discovery, cyan trace,
  /// purple most-recent RX.
  let typeColor: WatchColor
}

struct WatchGeo: Codable, Hashable {
  let you: WatchPosition?
  let pings: [WatchPing]
  let repeaters: [WatchRepeater]
  let heard: [WatchHeardNode]
  /// Repeater IDs the last ping reached, for the optional map lines.
  let linkedRepeaterIds: [String]
}

// MARK: - Controls

/// What the wrist is allowed to do right now.
///
/// These drive button enablement only. The phone revalidates every command
/// against the same guards the in-app buttons use, so a stale payload can
/// never talk the phone into an illegal transmit.
struct WatchControls: Codable, Hashable {
  let canStartStop: Bool
  let canManualPing: Bool
  let isSessionActive: Bool
  /// Absolute deadline for the 15 s manual cooldown, if one is running.
  let manualCooldownEndsAtMs: Double?
  /// Human-readable reason a control is unavailable ("Not connected").
  let blockedReason: String?
}

// MARK: - Haptics

/// A one-shot event the watch should feel.
///
/// Carries an `id` so the watch fires exactly once per event: state diffing
/// would double-fire on redelivery, which WatchConnectivity does routinely.
struct WatchHapticCue: Codable, Hashable {
  let id: String
  /// "success" | "failure" | "notification"
  let kind: String
  /// Optional is an additive wire change: v2 payloads without it still decode,
  /// and the matched phone and watch targets ship the new field together.
  let message: String?
}

// MARK: - Snapshot

/// The complete state the watch renders.
struct WatchSnapshot: Codable, Hashable {
  let wireVersion: Int
  let sessionId: String

  // Session core — mirrors the Live Activity's fields so both surfaces agree.
  let mode: String
  let phase: String
  let phaseTitle: String
  let phaseDetail: String?
  let phaseEndsAtMs: Double?
  /// Total length of the current phase, so the watch can draw a depleting bar
  /// locally. Absent when no countdown owns the deadline.
  let phaseDurationMs: Int?
  let isConnected: Bool
  let zoneCode: String?
  let txCount: Int
  let rxCount: Int
  let discoveryCount: Int
  let traceCount: Int
  let queueSize: Int

  /// Colour of the most recent completed ping result.
  let pingColor: WatchColor?

  let geo: WatchGeo
  let controls: WatchControls
  let cue: WatchHapticCue?
  let updatedAtMs: Double

  /// True when this payload came from a wire version the app understands.
  var isSupportedVersion: Bool { wireVersion == MeshMapperWatchWire.version }

  var updatedAt: Date {
    Date(timeIntervalSince1970: updatedAtMs / 1000)
  }

  var phaseEndsAt: Date? {
    phaseEndsAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
  }

  /// Fraction of the current phase still to run, 0...1.
  ///
  /// Computed from absolute values at render time, so it stays correct between
  /// updates and when the app opens midway through a phase. Nil when no
  /// countdown owns the deadline, in which case no bar is drawn.
  func phaseRemainingFraction(at now: Date = Date()) -> Double? {
    guard let phaseEndsAt, let phaseDurationMs, phaseDurationMs > 0 else { return nil }
    let remaining = phaseEndsAt.timeIntervalSince(now)
    guard remaining > 0 else { return 0 }
    return min(1, remaining / (Double(phaseDurationMs) / 1000))
  }
}

// MARK: - Commands (watch → phone)

/// An intent from the wrist. Never state — the phone decides what happens.
struct WatchCommand: Codable, Hashable {
  enum Kind: String, Codable {
    case startSession
    case stopSession
    case manualPing
    /// Watch asking for a fresh snapshot (e.g. app just came to the front).
    case requestSnapshot
  }

  let kind: Kind
  /// Client-generated, so the phone can dedupe redelivered commands.
  let id: String
}

/// The phone's answer to a command.
struct WatchCommandAck: Codable, Hashable {
  let id: String
  let accepted: Bool
  /// Why it was refused, for display on the wrist.
  let reason: String?
}

// MARK: - Coding helpers

extension MeshMapperWatchWire {
  static let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    return encoder
  }()

  static let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    return decoder
  }()

  /// Key used for the single `Data` blob inside a WatchConnectivity payload.
  static let payloadKey = "snapshot"
  static let commandKey = "command"
}
