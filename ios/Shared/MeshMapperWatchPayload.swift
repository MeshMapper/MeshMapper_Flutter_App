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
  ///
  /// Additive optional fields stay on v2: this decoder defaults an older
  /// phone's missing mode list to Passive and missing Ping applicability to
  /// false, while an older phone safely ignores a command's new mode field.
  /// Rejecting that pair would add no protection.
  static let version = 2

  /// Caps, mirrored in Dart and enforced by `WatchGeoBuilder` on send.
  ///
  /// The receiving side does not truncate: these values describe what the phone
  /// promises to send, and the views size themselves from what actually
  /// arrives. A peer that ignored them would render more rows, not crash.
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
  /// Full repeater hex. Heard path hashes are prefixes of this value; the API
  /// database ID above belongs to a different identity domain.
  // Optional only for one-version migration: a new watch can receive the
  // phone's previously persisted v2 application context before the matching
  // app update replaces it. New Dart payloads always provide this field.
  let hexId: String?
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
  /// Stable slot ownership, separate from transient ping enablement.
  let manualPingApplicable: Bool
  /// Absolute deadline for the 15 s manual cooldown, if one is running.
  let manualCooldownEndsAtMs: Double?
  /// Human-readable reason a control is unavailable ("Not connected").
  let blockedReason: String?

  init(
    canStartStop: Bool,
    canManualPing: Bool,
    isSessionActive: Bool,
    manualPingApplicable: Bool = false,
    manualCooldownEndsAtMs: Double?,
    blockedReason: String?
  ) {
    self.canStartStop = canStartStop
    self.canManualPing = canManualPing
    self.isSessionActive = isSessionActive
    self.manualPingApplicable = manualPingApplicable
    self.manualCooldownEndsAtMs = manualCooldownEndsAtMs
    self.blockedReason = blockedReason
  }

  private enum CodingKeys: String, CodingKey {
    case canStartStop, canManualPing, isSessionActive
    case manualPingApplicable, manualCooldownEndsAtMs, blockedReason
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    canStartStop = try values.decode(Bool.self, forKey: .canStartStop)
    canManualPing = try values.decode(Bool.self, forKey: .canManualPing)
    isSessionActive = try values.decode(Bool.self, forKey: .isSessionActive)
    // Additive v2 field. An older phone cannot promise stable Ping ownership,
    // so preserving the established Stop slot is the conservative default.
    manualPingApplicable = try values.decodeIfPresent(
      Bool.self,
      forKey: .manualPingApplicable
    ) ?? false
    manualCooldownEndsAtMs = try values.decodeIfPresent(
      Double.self,
      forKey: .manualCooldownEndsAtMs
    )
    blockedReason = try values.decodeIfPresent(String.self, forKey: .blockedReason)
  }
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
  /// Optional for migration, but new phones always send it. A watch must not
  /// replay an undated cue retained by an older application context.
  let issuedAtMs: Double?
  /// Optional is an additive wire change: v2 payloads without it still decode,
  /// and the matched phone and watch targets ship the new field together.
  let message: String?

  var issuedAt: Date? {
    issuedAtMs.map { Date(timeIntervalSince1970: $0 / 1000) }
  }
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

  /// Lowercase mode names the phone currently permits for a wrist start.
  /// This is policy resolved by the phone, not enough raw state for the watch
  /// to derive policy independently.
  let availableStartModes: [String]

  /// False means the map-only arrays were intentionally cleared. Missing on
  /// older additive-v2 payloads means full geography, the fail-safe default.
  let mapGeoIncluded: Bool
  let geo: WatchGeo
  let controls: WatchControls
  let cue: WatchHapticCue?
  let updatedAtMs: Double

  init(
    wireVersion: Int,
    sessionId: String,
    mode: String,
    phase: String,
    phaseTitle: String,
    phaseDetail: String?,
    phaseEndsAtMs: Double?,
    phaseDurationMs: Int?,
    isConnected: Bool,
    zoneCode: String?,
    txCount: Int,
    rxCount: Int,
    discoveryCount: Int,
    traceCount: Int,
    queueSize: Int,
    pingColor: WatchColor?,
    availableStartModes: [String] = ["passive"],
    mapGeoIncluded: Bool = true,
    geo: WatchGeo,
    controls: WatchControls,
    cue: WatchHapticCue?,
    updatedAtMs: Double
  ) {
    self.wireVersion = wireVersion
    self.sessionId = sessionId
    self.mode = mode
    self.phase = phase
    self.phaseTitle = phaseTitle
    self.phaseDetail = phaseDetail
    self.phaseEndsAtMs = phaseEndsAtMs
    self.phaseDurationMs = phaseDurationMs
    self.isConnected = isConnected
    self.zoneCode = zoneCode
    self.txCount = txCount
    self.rxCount = rxCount
    self.discoveryCount = discoveryCount
    self.traceCount = traceCount
    self.queueSize = queueSize
    self.pingColor = pingColor
    self.availableStartModes = availableStartModes
    self.mapGeoIncluded = mapGeoIncluded
    self.geo = geo
    self.controls = controls
    self.cue = cue
    self.updatedAtMs = updatedAtMs
  }

  private enum CodingKeys: String, CodingKey {
    case wireVersion, sessionId, mode, phase, phaseTitle, phaseDetail
    case phaseEndsAtMs, phaseDurationMs, isConnected, zoneCode
    case txCount, rxCount, discoveryCount, traceCount, queueSize, pingColor
    case availableStartModes, mapGeoIncluded, geo, controls, cue, updatedAtMs
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    wireVersion = try values.decode(Int.self, forKey: .wireVersion)
    sessionId = try values.decode(String.self, forKey: .sessionId)
    mode = try values.decode(String.self, forKey: .mode)
    phase = try values.decode(String.self, forKey: .phase)
    phaseTitle = try values.decode(String.self, forKey: .phaseTitle)
    phaseDetail = try values.decodeIfPresent(String.self, forKey: .phaseDetail)
    phaseEndsAtMs = try values.decodeIfPresent(Double.self, forKey: .phaseEndsAtMs)
    phaseDurationMs = try values.decodeIfPresent(Int.self, forKey: .phaseDurationMs)
    isConnected = try values.decode(Bool.self, forKey: .isConnected)
    zoneCode = try values.decodeIfPresent(String.self, forKey: .zoneCode)
    txCount = try values.decode(Int.self, forKey: .txCount)
    rxCount = try values.decode(Int.self, forKey: .rxCount)
    discoveryCount = try values.decode(Int.self, forKey: .discoveryCount)
    traceCount = try values.decode(Int.self, forKey: .traceCount)
    queueSize = try values.decode(Int.self, forKey: .queueSize)
    pingColor = try values.decodeIfPresent(WatchColor.self, forKey: .pingColor)
    // Additive v2 field: an older phone omits it, and Passive is the only mode
    // safe to promise without current phone-resolved zone policy. Keeping v2
    // avoids stranding otherwise compatible phone/watch pairs.
    availableStartModes = try values.decodeIfPresent(
      [String].self,
      forKey: .availableStartModes
    ) ?? ["passive"]
    // Additive v2 field. An old phone always sends full geography, so absence
    // must mean included; treating it as suppressed could blank a real map.
    mapGeoIncluded = try values.decodeIfPresent(
      Bool.self,
      forKey: .mapGeoIncluded
    ) ?? true
    geo = try values.decode(WatchGeo.self, forKey: .geo)
    controls = try values.decode(WatchControls.self, forKey: .controls)
    cue = try values.decodeIfPresent(WatchHapticCue.self, forKey: .cue)
    updatedAtMs = try values.decode(Double.self, forKey: .updatedAtMs)
  }

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
  /// Optional additive field. Older phones ignore it and retain their safe
  /// mode resolver; new phones revalidate it instead of silently downgrading.
  let mode: String?
  /// Optional map-demand state carried only by requestSnapshot. An old phone
  /// ignores it and keeps sending full geography, so wire v2 remains safe.
  let mapGeoNeeded: Bool?
  /// Whether this is a genuine plea for current state, rather than a change of
  /// map demand that happens to travel as the same command.
  ///
  /// `requestSnapshot` carries both intents. Only the first should defeat the
  /// phone's unchanged-state dedupe: the map-geo lease renews every five
  /// minutes for as long as the map stays hidden, and forcing an identical
  /// snapshot each time would spend the radio precisely where the lease exists
  /// to save it. The distinction is stated rather than inferred from
  /// `mapGeoNeeded`, which the phone may legitimately resolve to nil when a
  /// suppression claim arrives stale or out of order.
  ///
  /// Optional for the usual reason: absent means false, so a phone paired with
  /// an older watch build behaves exactly as it did before.
  let forceRefresh: Bool?
  /// Client-generated, so the phone can dedupe redelivered commands.
  let id: String
  /// Queued delivery can outlive the place where a transmit was requested.
  /// The phone uses this to reject stale actions before admission.
  ///
  /// Stamped in the *watch's* clock, deliberately. It doubles as the ordering
  /// key for map-geo suppression claims, and rewriting it into phone time
  /// would make that key jump the moment an offset is first learned — turning
  /// a monotonic sequence into one where a newer claim can look older.
  let issuedAtMs: Double
  /// The watch's estimate of phone-clock minus watch-clock, in milliseconds.
  ///
  /// Optional and additive, so an older phone ignores it and behaves exactly as
  /// before. It lets the phone measure this command's *age* in its own clock
  /// without the two devices having to agree on what time it is: an unshared
  /// clock is a normal condition, and the transmit-age window used to turn any
  /// disagreement past five seconds into "every command refused" rather than
  /// into a slightly wider margin.
  ///
  /// Learned only from a live `sendMessage`, whose transit is milliseconds. An
  /// application context can sit retained for hours, so its timestamp says
  /// nothing about the current offset.
  let clockOffsetMs: Double?
  /// Which session a `stopSession` means, from the snapshot the wearer was
  /// looking at when they tapped.
  ///
  /// Stopping is exempt from the transmit-age window — a late stop takes the
  /// radio off air, so refusing it is the worse failure — but that exemption
  /// assumed sessions were interchangeable. They are not: a Stop queued while
  /// the phone was out of range, delivered after that session ended and
  /// another began, silently stopped the wrong one and the wearer learned
  /// about it by noticing that recording had halted.
  ///
  /// Optional and additive. Absent — an older watch build — the phone admits
  /// the stop exactly as it always did.
  let sessionId: String?
}

// There is deliberately no acknowledgement model: queued commands have no
// reply channel; state snapshots and failure cues carry every outcome.

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

/// The wire's timing rules, as pure functions.
///
/// These decide what the wearer sees: whether an arriving payload supersedes
/// the one on screen, how old a snapshot is allowed to look before the surface
/// greys, and whether a failure cue is buzzed, shown silently, or dropped.
///
/// **They live here to be testable.** `WatchSessionClient` is `@Observable`,
/// `@MainActor`, and reaches `WCSession.default` through a computed property
/// with no injection point, so nothing inside it can be exercised without a
/// paired watch. These rules need none of that — a date, an optional offset,
/// and a decoded payload — and this file is already Foundation-only and
/// already compiled into every target that needs it, so moving them costs no
/// project surgery. `WatchLogicTests` runs them under `swift test` on any
/// toolchain; the client keeps the observable state and the timers.
///
/// Phone-side mirrors live in `lib/services/watch/watch_models.dart`:
/// `WatchWire.cueReadableFor` tracks `staleAfter`, and the phone stops
/// attaching a cue at the same boundary the watch stops presenting one.
enum WatchWireRules {
  /// A snapshot older than this is shown greyed with an age badge. The phone
  /// only sends on real change, so silence is normal — this threshold is
  /// about "the phone has probably gone away", not "no update recently".
  static let staleAfter: TimeInterval = 90

  /// Recent enough that the wearer can still connect a buzz to what they did.
  static let cueFreshFor: TimeInterval = 30

  /// Phone and watch clocks normally agree to well under a second. This is the
  /// slack allowed anywhere a phone-stamped time is compared against watch
  /// "now", and mirrors the tolerance the phone applies to watch commands.
  static let clockTolerance: TimeInterval = 5

  /// How much of a cue is still worth presenting, given its age.
  enum CuePresentation {
    /// Recent enough that the wearer can connect the buzz to what they did.
    case feel
    /// Too old to buzz for, but still the only account of the failure they
    /// will ever get: the phone attaches a cue until it passes `staleAfter`,
    /// and most of that window is spent with the wrist down.
    case read
    case drop
  }

  /// A phone-stamped instant expressed in this watch's clock.
  static func inLocalTime(
    _ phoneInstant: Date,
    clockOffset: TimeInterval?
  ) -> Date {
    guard let clockOffset else { return phoneInstant }
    return phoneInstant.addingTimeInterval(-clockOffset)
  }

  /// A wrist-down interval longer than [cueFreshFor] used to discard the cue
  /// outright — no haptic *and* no message — so a wearer who tapped Start,
  /// dropped their wrist and looked back a minute later was never told why the
  /// session had not begun. Buzzing for something that old is wrong, but
  /// staying silent about it is worse.
  ///
  /// The upper bound is [staleAfter], the same boundary that greys the rest of
  /// the screen: past it the wearer is already being told the whole surface is
  /// old, and a banner asserting a stale failure as current would be its own
  /// lie.
  static func presentation(
    for cue: WatchHapticCue,
    at arrival: Date,
    clockOffset: TimeInterval?
  ) -> CuePresentation {
    guard let issuedAt = cue.issuedAt else { return .drop }
    let age = arrival.timeIntervalSince(
      inLocalTime(issuedAt, clockOffset: clockOffset)
    )
    // A few seconds of skew must not suppress a real failure that has just
    // crossed the radio.
    guard age >= -clockTolerance else { return .drop }
    if age <= cueFreshFor { return .feel }
    return age <= staleAfter ? .read : .drop
  }

  /// Whether `incoming` supersedes what is already rendered.
  ///
  /// **The two delivery paths are not ordered with respect to each other.** An
  /// urgent update goes out as `sendMessage` *and* as
  /// `updateApplicationContext`, and only the first is fast. `sendMessage`
  /// does not populate `receivedApplicationContext`, so the retained context
  /// keeps whatever last arrived down the slow path — which can be a payload
  /// already superseded live. `resume` ingests that context on every wrist
  /// raise, and last-writer-wins then walks the wearer backwards onto state
  /// that is under 90 s old, so nothing asks for better.
  ///
  /// Both stamps come from the one phone clock, so they compare raw —
  /// `inLocalTime` is for phone-instant against watch-now, which this is not.
  /// Equal stamps are accepted: two payloads built in the same millisecond are
  /// interchangeable, and a forced refresh always restamps `updatedAt`, so it
  /// can never be mistaken for a replay of itself.
  ///
  /// **A stale surface accepts anything.** Ordering is worth enforcing only
  /// while what is held is still worth protecting. Bounding it this way means
  /// the worst case of a phone clock stepping backwards is 90 seconds of
  /// refusal, after which the boundary flips and the watch recovers on its
  /// own. A bare comparison would refuse for the life of the process.
  static func supersedes(
    _ incoming: WatchSnapshot,
    current: WatchSnapshot?,
    isStale: Bool
  ) -> Bool {
    guard let current, !isStale else { return true }
    return incoming.updatedAt >= current.updatedAt
  }

  /// When a snapshot should be aged from, and how long it has left.
  ///
  /// Age from when the phone built the payload rather than when it reached the
  /// wrist. Launch ingests whatever application context WatchConnectivity
  /// retained, which can be hours old, and stamping arrival there would
  /// present long-dead state as fresh for a full 90 seconds.
  ///
  /// Clamped to `arrival` so a phone clock running fast cannot date a snapshot
  /// into the future and extend its life, with [clockTolerance] of slack so
  /// ordinary skew does not age a genuinely live payload early.
  ///
  /// A non-positive `remaining` means the payload is already stale on arrival.
  static func reception(
    arrival: Date,
    producedAt: Date?,
    clockOffset: TimeInterval?
  ) -> (origin: Date, remaining: TimeInterval) {
    let origin =
      producedAt
        .map { inLocalTime($0, clockOffset: clockOffset) }
        .map { min(arrival, $0.addingTimeInterval(clockTolerance)) } ?? arrival
    return (origin, staleAfter - arrival.timeIntervalSince(origin))
  }
}
