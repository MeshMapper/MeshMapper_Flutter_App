#if DEBUG
import Foundation

/// Synthetic state for design work and headless verification.
///
/// The simulator has no Bluetooth, so a paired simulator pair can never
/// produce pings or repeaters — the map would always be empty there. Enable
/// with a launch argument:
///
///     xcrun simctl launch <watch> net.meshmapper.app.watchkitapp -MeshMapperSampleData YES
///
/// Other DEBUG launch arguments used by the capture harness:
///
/// - `-MeshMapperSamplePhase listen|wait|lapsed` exercises phase timing.
/// - `-MeshMapperSampleControls active|idle|blocked|cooldown|passiveOnly|txActive`
///   exercises every toolbar slot state.
/// - `-MeshMapperLongIds YES` exercises six-character path hashes.
/// - `-MeshMapperShowNodeSheet YES` opens the heard-node sheet.
/// - `-MeshMapperInitialPage <tag>` opens a specific vertical page.
/// - `-MeshMapperForceDimmed YES` renders the reduced-luminance readout.
/// - `-MeshMapperForceRefusal <message>` presents the failure banner; capture
///   within six seconds because it deliberately uses the production expiry.
/// - `-MeshMapperAutoPageTo <tag>` switches pages five seconds after launch.
///   The simulator cannot swipe, and page transitions are a real defect
///   surface: a sheet raised from the map once survived onto the next page,
///   blurring it and swallowing every swipe, which reads exactly like a crash.
/// - `-MeshMapperTimeSwitchToMap YES` flips the main page to the map five
///   seconds after launch and logs `[switch] requesting map at <epoch>`, so the
///   MapKit rebuild a wrist raise pays can be timed against screenshot mtimes.
///   Always pass `-layout.mainPageContent readout` with it: starting on the map
///   makes the flip a no-op that still logs, which looks like a fast result.
///   It also logs `[span] rendered … requested … confirmed …` on every camera
///   callback, which is how to check on hardware whether a rebuilt map ever
///   reports a region that is not the one we asked for. In the simulator it
///   never does — three teardown cycles, 0.0% drift every time.
///
/// Listening and active remain the defaults so existing capture commands keep
/// their behaviour.
///
/// Every affordance is DEBUG-only and requires its explicit argument, so none
/// can leak into a shipping build or mask a real transport failure.
enum SampleSnapshot {
  static var isEnabled: Bool {
    UserDefaults.standard.bool(forKey: "MeshMapperSampleData")
  }

  /// Downtown Seattle, roughly — somewhere with enough spread to see marker
  /// density and line geometry at a realistic zoom.
  private static let originLat = 47.6062
  private static let originLon = -122.3321

  static func make() -> WatchSnapshot {
    let now = Date().timeIntervalSince1970 * 1000

    let samplePhase: (name: String, title: String, endsAtMs: Double, durationMs: Int)
    switch UserDefaults.standard.string(forKey: "MeshMapperSamplePhase") {
    case "wait":
      samplePhase = ("waiting", "Next ping", now + 25_000, 30_000)
    case "lapsed":
      samplePhase = ("listening", "Listening…", now - 5_000, 60_000)
    default:
      samplePhase = ("listening", "Listening…", now + 42_000, 60_000)
    }

    let sampleControlState = UserDefaults.standard.string(
      forKey: "MeshMapperSampleControls"
    )
    let sampleControls: WatchControls
    switch sampleControlState {
    case "idle":
      sampleControls = WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: false,
        manualPingApplicable: true,
        manualCooldownEndsAtMs: nil,
        blockedReason: nil
      )
    case "blocked":
      sampleControls = WatchControls(
        canStartStop: false,
        canManualPing: false,
        isSessionActive: false,
        manualPingApplicable: false,
        manualCooldownEndsAtMs: nil,
        blockedReason: "This zone is currently passive-only"
      )
    case "cooldown":
      // The one unavailability the phone reports with no `blockedReason`.
      sampleControls = WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: true,
        manualPingApplicable: true,
        manualCooldownEndsAtMs: now + 12_000,
        blockedReason: nil
      )
    case "passiveOnly":
      sampleControls = WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: true,
        manualPingApplicable: false,
        manualCooldownEndsAtMs: nil,
        blockedReason: "Passive Only"
      )
    case "txActive":
      sampleControls = WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: true,
        manualPingApplicable: false,
        manualCooldownEndsAtMs: nil,
        blockedReason: nil
      )
    default:
      sampleControls = WatchControls(
        canStartStop: true,
        canManualPing: true,
        isSessionActive: true,
        manualPingApplicable: true,
        manualCooldownEndsAtMs: nil,
        blockedReason: nil
      )
    }

    let green = WatchColor(r: 0.30, g: 0.69, b: 0.31)
    let red = WatchColor(r: 0.96, g: 0.26, b: 0.21)
    let purple = WatchColor(r: 0.49, g: 0.33, b: 0.78)
    let pink = WatchColor(r: 0.84, g: 0.20, b: 0.52)
    let orange = WatchColor(r: 0.99, g: 0.49, b: 0.08)

    // A drive west-to-east with a mix of answered and unanswered pings.
    let pings: [WatchPing] = (0..<40).map { i in
      let answered = i % 3 != 0
      return WatchPing(
        id: "p\(i)",
        lat: originLat + Double(i) * 0.00035 + (i % 2 == 0 ? 0.0002 : -0.0002),
        lon: originLon + Double(i) * 0.00085,
        kind: i % 5 == 0 ? "rx" : "tx",
        color: i % 5 == 0 ? purple : (answered ? green : red),
        atMs: now - Double(40 - i) * 20_000
      )
    }

    let repeaters: [WatchRepeater] = [
      ("4E", "Capitol Hill", 0.010, 0.004, pink, true),
      ("77", "Queen Anne", -0.006, 0.012, pink, true),
      ("A2", "Beacon Hill", -0.012, -0.008, orange, false),
      ("B9", "Magnolia", 0.004, -0.015, pink, false),
    ].map { id, name, dLat, dLon, color, heard in
      WatchRepeater(
        id: id,
        hexId: id,
        name: name,
        lat: originLat + dLat,
        lon: originLon + dLon,
        color: color,
        heardThisCycle: heard
      )
    }

    // Mirrors the phone's "Top Heard": three rows from the latest ping, then
    // the RX slot in purple. Names are deliberately mixed — a 4-char hash
    // resolves, a 2-char one often cannot.
    let teal = WatchColor(r: 0.32, g: 0.83, b: 0.91)
    // Pass -MeshMapperLongIds YES to render the 3-byte-zone worst case: six
    // hex characters per row, which is what the box has to survive on 40 mm.
    let long = UserDefaults.standard.bool(forKey: "MeshMapperLongIds")
    let heard: [WatchHeardNode] = [
      (long ? "4E5D82" : "4E5D", "Capitol Hill", 8.5, 1420.0, green),
      (long ? "77A1B0" : "77A1", nil, 2.25, 2310.0, teal),
      (long ? "A2FF31" : "A2", nil, -14.5, nil, green),
      (long ? "B914C2" : "B914", "Magnolia", 5.75, 2870.0, purple),
    ].map { id, name, snr, distance, typeColor in
      WatchHeardNode(
        id: id,
        name: name,
        snr: snr,
        atMs: now - 30_000,
        distanceM: distance,
        snrColor: snr > 5
          ? WatchColor(r: 0.30, g: 0.69, b: 0.31)
          : (snr > -1
            ? WatchColor(r: 1.0, g: 0.60, b: 0.0)
            : WatchColor(r: 0.96, g: 0.26, b: 0.21)),
        typeColor: typeColor
      )
    }

    return WatchSnapshot(
      wireVersion: MeshMapperWatchWire.version,
      sessionId: "sample",
      // Ping can own the active-session slot only during Passive monitoring;
      // Active and Hybrid are TX modes and keep Stop reachable instead.
      mode: sampleControlState == "txActive" ? "Hybrid" : "Passive",
      phase: samplePhase.name,
      phaseTitle: samplePhase.title,
      phaseDetail: "Waiting for echoes",
      phaseEndsAtMs: samplePhase.endsAtMs,
      phaseDurationMs: samplePhase.durationMs,
      isConnected: true,
      zoneCode: "SEA",
      txCount: 27,
      rxCount: 14,
      discoveryCount: 6,
      traceCount: 0,
      queueSize: 2,
      pingColor: green,
      availableStartModes: sampleControlState == "passiveOnly"
        ? ["passive"]
        : ["passive", "hybrid"],
      geo: WatchGeo(
        you: WatchPosition(
          lat: originLat + 0.006,
          lon: originLon + 0.014,
          headingDeg: 72,
          accuracyM: 8,
          fixedAtMs: now
        ),
        pings: pings,
        repeaters: repeaters,
        heard: heard,
        linkedRepeaterIds: ["4E", "77"]
      ),
      controls: sampleControls,
      cue: nil,
      updatedAtMs: now
    )
  }
}
#endif
