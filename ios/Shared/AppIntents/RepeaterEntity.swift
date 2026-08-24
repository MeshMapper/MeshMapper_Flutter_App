import AppIntents
import CoreSpotlight
import Foundation

@available(iOS 26.0, *)
struct RepeaterEntity: AppEntity, IndexedEntity {
  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "MeshMapper Repeater",
    numericFormat: "\(placeholder: .int) repeaters"
  )
  static var defaultQuery = RepeaterEntityQuery()

  let id: String
  let name: String
  let hexId: String
  let zoneCode: String?
  let isActive: Bool
  let isNew: Bool
  let serverLastHeardMs: Int64?
  let latitude: Double?
  let longitude: Double?

  init(snapshot: MeshMapperSiriRepeater) {
    id = snapshot.id
    name = snapshot.name
    hexId = snapshot.hexId
    zoneCode = snapshot.zoneCode
    isActive = snapshot.isActive
    isNew = snapshot.isNew
    serverLastHeardMs = snapshot.serverLastHeardMs
    latitude = snapshot.latitude
    longitude = snapshot.longitude
  }

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(
      title: "\(name)",
      subtitle: zoneCode.map { "\($0) · \(hexId)" } ?? "\(hexId)"
    )
  }

  var attributeSet: CSSearchableItemAttributeSet {
    let attributes = defaultAttributeSet
    attributes.title = name
    attributes.contentDescription = [zoneCode, hexId]
      .compactMap { $0 }
      .joined(separator: " · ")
    attributes.keywords = [name, hexId, zoneCode].compactMap { $0 }
    if let latitude, let longitude {
      attributes.latitude = latitude as NSNumber
      attributes.longitude = longitude as NSNumber
    }
    return attributes
  }
}

@available(iOS 26.0, *)
struct RepeaterEntityQuery: EntityStringQuery {
  func entities(for identifiers: [RepeaterEntity.ID]) async throws -> [RepeaterEntity] {
    let wanted = Set(identifiers)
    return try catalog().filter { wanted.contains($0.id) }
  }

  func entities(matching string: String) async throws -> [RepeaterEntity] {
    let needle = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return try catalog() }
    return try catalog().filter {
      $0.name.localizedCaseInsensitiveContains(needle)
        || $0.hexId.localizedCaseInsensitiveContains(needle)
        || ($0.zoneCode?.localizedCaseInsensitiveContains(needle) ?? false)
    }
  }

  func suggestedEntities() async throws -> [RepeaterEntity] {
    Array(try catalog().filter(\.isActive).prefix(20))
  }

  private func catalog() throws -> [RepeaterEntity] {
    try MeshMapperSiriSnapshotStore.shared.read()?
      .repeaters
      .map(RepeaterEntity.init(snapshot:)) ?? []
  }
}
