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
/// DEBUG-only, and never reached unless that argument is passed, so it cannot
/// leak into a shipping build or mask a real transport failure.
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
        name: name,
        lat: originLat + dLat,
        lon: originLon + dLon,
        color: color,
        heardThisCycle: heard
      )
    }

    let heard: [WatchHeardNode] = [
      ("4E", "Capitol Hill", 8.5, -71, nil, 3, 1420.0),
      ("77", "Queen Anne", 2.25, -94, 1, 2, 2310.0),
      ("A2", "Beacon Hill", -4.0, -112, 2, 1, 3050.0),
    ].map { id, name, snr, rssi, hops, seen, distance in
      WatchHeardNode(
        id: id,
        name: name,
        snr: snr,
        rssi: rssi,
        hops: hops,
        seenCount: seen,
        atMs: now - 30_000,
        distanceM: distance,
        snrColor: snr > 5
          ? WatchColor(r: 0.30, g: 0.69, b: 0.31)
          : (snr > -1
            ? WatchColor(r: 1.0, g: 0.60, b: 0.0)
            : WatchColor(r: 0.96, g: 0.26, b: 0.21))
      )
    }

    return WatchSnapshot(
      wireVersion: MeshMapperWatchWire.version,
      sessionId: "sample",
      mode: "Active",
      phase: "listening",
      phaseTitle: "Listening",
      phaseDetail: "Waiting for echoes",
      phaseEndsAtMs: now + 42_000,
      isConnected: true,
      zoneCode: "SEA",
      txCount: 27,
      rxCount: 14,
      discoveryCount: 6,
      traceCount: 0,
      queueSize: 2,
      pingColor: green,
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
      controls: WatchControls(
        canStartStop: true,
        canManualPing: true,
        isSessionActive: true,
        manualCooldownEndsAtMs: nil,
        blockedReason: nil
      ),
      cue: nil,
      updatedAtMs: now
    )
  }
}
#endif
