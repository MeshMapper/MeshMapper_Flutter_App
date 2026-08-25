import Foundation

struct MeshMapperSiriSnapshot: Codable, Sendable {
  let version: Int
  let updatedAtMs: Int64
  let connection: MeshMapperSiriConnection
  let session: MeshMapperSiriSession
  let controls: MeshMapperSiriControls
  let recentHeard: [MeshMapperSiriObservation]
  let repeaters: [MeshMapperSiriRepeater]

  var updatedAt: Date {
    Date(timeIntervalSince1970: Double(updatedAtMs) / 1_000)
  }
}

struct MeshMapperSiriConnection: Codable, Sendable {
  let isConnected: Bool
  let deviceName: String?
  let batteryPercent: Int?
  let gpsStatus: String
}

struct MeshMapperSiriSession: Codable, Sendable {
  let id: String?
  /// Additive and optional, so a snapshot written by an older build still
  /// decodes; nil simply means "no session boundary is known".
  let startedAtMs: Int64?
  let active: Bool
  let starting: Bool
  let mode: String
  let phase: String
  let phaseTitle: String
  let phaseDetail: String?
  let phaseEndsAtMs: Int64?
  let zoneCode: String?
  let txCount: Int
  let rxCount: Int
  let discoveryCount: Int
  let traceCount: Int
  let queueSize: Int
  let uniqueRepeatersHeard: Int

  var startedAt: Date? {
    startedAtMs.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
  }
}

struct MeshMapperSiriControls: Codable, Sendable {
  let availableStartModes: [String]
  let canStart: Bool
  let startBlockedReason: String?
  let canStop: Bool
  let canManualPing: Bool
  let manualPingBlockedReason: String?
  let manualCooldownEndsAtMs: Int64?
}

struct MeshMapperSiriObservation: Codable, Sendable {
  let entityId: String?
  let displayHexId: String
  let name: String?
  let observedAtMs: Int64
  let kind: String
  let direct: Bool
  let hopCount: Int
  let snr: Double?
  let rssi: Int?
  let distanceM: Double?
  let repeaterLat: Double?
  let repeaterLon: Double?
  let resolved: Bool

  var observedAt: Date {
    Date(timeIntervalSince1970: Double(observedAtMs) / 1_000)
  }

  var stableEntityIdentifier: String {
    [
      entityId ?? displayHexId,
      String(observedAtMs),
      kind,
      direct ? "direct" : "routed",
      String(hopCount),
    ].joined(separator: "|")
  }
}

struct MeshMapperSiriRepeater: Codable, Sendable {
  let id: String
  let name: String
  let hexId: String
  let zoneCode: String?
  let isActive: Bool
  let isNew: Bool
  let serverLastHeardMs: Int64?
  let latitude: Double?
  let longitude: Double?
}
