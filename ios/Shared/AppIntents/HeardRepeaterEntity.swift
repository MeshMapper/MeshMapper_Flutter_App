import AppIntents
import Foundation

@available(iOS 26.0, *)
struct HeardRepeaterEntity: AppEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "Heard MeshMapper Repeater",
    numericFormat: "\(placeholder: .int) heard repeaters"
  )
  static var defaultQuery = HeardRepeaterEntityQuery()

  let id: String
  let repeater: RepeaterEntity?
  let displayHexId: String
  let observedAtMs: Int64
  let snr: Double?
  let distanceM: Double?
  let kind: String
  let direct: Bool

  init(
    observation: MeshMapperSiriObservation,
    repeaterById: [String: MeshMapperSiriRepeater]
  ) {
    // Derived only from observation content so sorting, filtering, or limiting
    // cannot change the ID a saved Shortcut later asks EntityQuery to resolve.
    id = observation.stableEntityIdentifier
    if let entityId = observation.entityId,
       let repeaterSnapshot = repeaterById[entityId] {
      repeater = RepeaterEntity(snapshot: repeaterSnapshot)
    } else {
      repeater = nil
    }
    displayHexId = observation.displayHexId
    observedAtMs = observation.observedAtMs
    snr = observation.snr
    distanceM = observation.distanceM
    kind = observation.kind
    direct = observation.direct
  }

  var displayRepresentation: DisplayRepresentation {
    let title = repeater?.name ?? "Repeater \(displayHexId)"
    let subtitle = snr.map { String(format: "%.1f dB", $0) }
    return DisplayRepresentation(
      title: "\(title)",
      subtitle: subtitle.map { "\($0)" }
    )
  }
}

@available(iOS 26.0, *)
struct HeardRepeaterEntityQuery: EntityQuery {
  func entities(for identifiers: [HeardRepeaterEntity.ID]) async throws -> [HeardRepeaterEntity] {
    let wanted = Set(identifiers)
    return try observations().filter { wanted.contains($0.id) }
  }

  func suggestedEntities() async throws -> [HeardRepeaterEntity] {
    Array(try observations().prefix(5))
  }

  private func observations() throws -> [HeardRepeaterEntity] {
    guard let snapshot = try MeshMapperSiriSnapshotStore.shared.read() else {
      return []
    }
    let repeaterById = Dictionary(
      snapshot.repeaters.map { ($0.id, $0) },
      uniquingKeysWith: { existing, _ in existing }
    )
    return snapshot.recentHeard.map {
      HeardRepeaterEntity(observation: $0, repeaterById: repeaterById)
    }
  }
}
