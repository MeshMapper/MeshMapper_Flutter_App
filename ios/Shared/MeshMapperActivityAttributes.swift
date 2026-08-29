import ActivityKit
import Foundation

/// Shared ActivityKit contract used by Runner and the widget extension.
/// Keep the payload compact because ActivityKit limits attributes and state.
@available(iOS 16.2, *)
struct MeshMapperActivityAttributes: ActivityAttributes {
  /// Same compact sRGB encoding as the watch payload. A separate Swift name
  /// avoids coupling the widget target to the watch-only contract source.
  struct ResolvedColor: Codable, Hashable {
    let r: Double
    let g: Double
    let b: Double
  }

  struct HeardRepeater: Codable, Hashable, Identifiable {
    let id: String
    let name: String?
    let snr: Double
    let typeColor: ResolvedColor?
    let snrColor: ResolvedColor?
  }

  struct ContentState: Codable, Hashable {
    var mode: String
    var phase: String
    var phaseTitle: String
    var phaseDetail: String?
    var phaseEndsAt: Date?
    var phaseDurationMs: Int?
    var pingColor: ResolvedColor?
    /// The running mode's identity color, phone-resolved from the active
    /// ping palette. Tints the lock screen's phase progress bar.
    var modeColor: ResolvedColor? = nil
    var isConnected: Bool
    var zoneCode: String?
    /// Bucketed to 2 dBm steps by the phone so poll jitter never mints an
    /// update. Defaulted so payloads from an app without the field still
    /// decode.
    var noiseFloorDbm: Int? = nil
    /// Companion radio battery, bucketed to 5 percent steps by the phone.
    var companionBatteryPct: Int? = nil
    /// The Settings switch: named rows (true) or the two-column hex grid.
    var showRepeaterNames: Bool? = nil
    var txCount: Int
    var rxCount: Int
    var discoveryCount: Int
    var traceCount: Int
    var queueSize: Int
    var repeaters: [HeardRepeater]
    var totalHeardCount: Int
    var repeatersAreCurrent: Bool
    var updatedAt: Date
  }

  let sessionID: String
}
