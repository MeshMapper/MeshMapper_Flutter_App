import AppIntents

@available(iOS 26.0, *)
enum MeshMapperSessionMode: String, AppEnum {
  case passive
  case active
  case hybrid

  static var typeDisplayRepresentation = TypeDisplayRepresentation(
    name: "MeshMapper Mode"
  )
  static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
    .passive: "Passive Discovery",
    .active: "Active",
    .hybrid: "Hybrid",
  ]

  var displayName: String {
    self == .passive ? "Passive Discovery" : rawValue.capitalized
  }
}
