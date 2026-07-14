import ActivityKit
import Foundation

/// Shared ActivityKit contract used by Runner and the widget extension.
/// Keep the payload compact because ActivityKit limits attributes and state.
@available(iOS 16.2, *)
struct MeshMapperActivityAttributes: ActivityAttributes {
  struct HeardRepeater: Codable, Hashable, Identifiable {
    let id: String
    let name: String?
    let snr: Double

    var displayName: String {
      let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      return trimmed.isEmpty ? id : trimmed
    }
  }

  struct ContentState: Codable, Hashable {
    var mode: String
    var phase: String
    var phaseTitle: String
    var phaseDetail: String?
    var phaseEndsAt: Date?
    var isConnected: Bool
    var zoneCode: String?
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
