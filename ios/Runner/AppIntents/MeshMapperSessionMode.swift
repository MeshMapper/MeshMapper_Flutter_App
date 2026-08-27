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
    .passive: DisplayRepresentation(
      title: "Passive Discovery",
      synonyms: ["Passive", "Listen Only", "Receive Only"]
    ),
    .active: DisplayRepresentation(
      title: "Active",
      synonyms: ["Active Mapping"]
    ),
    .hybrid: DisplayRepresentation(
      title: "Hybrid",
      synonyms: ["Hybrid Mapping"]
    ),
  ]

  var displayName: String {
    self == .passive ? "Passive Discovery" : rawValue.capitalized
  }
}
