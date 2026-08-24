import Foundation

enum MeshMapperSiriSnapshotStoreError: LocalizedError {
  case appGroupUnavailable
  case invalidPayload
  case unsupportedVersion(Int)

  var errorDescription: String? {
    switch self {
    case .appGroupUnavailable:
      return "The MeshMapper App Group is unavailable."
    case .invalidPayload:
      return "The Siri snapshot payload is invalid."
    case .unsupportedVersion(let version):
      return "Unsupported Siri snapshot version \(version)."
    }
  }
}

final class MeshMapperSiriSnapshotStore {
  static let shared = MeshMapperSiriSnapshotStore()
  static let appGroupIdentifier = "group.net.meshmapper.app.shared"
  static let supportedVersion = 1

  private let fileManager: FileManager
  private let decoder = JSONDecoder()
  private let encoder = JSONEncoder()

  init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
    encoder.outputFormatting = [.sortedKeys]
  }

  private var snapshotURL: URL? {
    fileManager
      .containerURL(
        forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
      )?
      .appendingPathComponent("siri-snapshot.json", isDirectory: false)
  }

  func writeFlutterPayload(_ arguments: Any?) throws {
    guard let arguments,
          JSONSerialization.isValidJSONObject(arguments)
    else {
      throw MeshMapperSiriSnapshotStoreError.invalidPayload
    }
    let incoming = try JSONSerialization.data(
      withJSONObject: arguments,
      options: [.sortedKeys]
    )
    let snapshot = try decoder.decode(MeshMapperSiriSnapshot.self, from: incoming)
    try write(snapshot)
  }

  func write(_ snapshot: MeshMapperSiriSnapshot) throws {
    guard snapshot.version == Self.supportedVersion else {
      throw MeshMapperSiriSnapshotStoreError.unsupportedVersion(snapshot.version)
    }
    guard let snapshotURL else {
      throw MeshMapperSiriSnapshotStoreError.appGroupUnavailable
    }
    let data = try encoder.encode(snapshot)
    try data.write(to: snapshotURL, options: .atomic)
  }

  func read() throws -> MeshMapperSiriSnapshot? {
    guard let snapshotURL else {
      throw MeshMapperSiriSnapshotStoreError.appGroupUnavailable
    }
    guard fileManager.fileExists(atPath: snapshotURL.path) else { return nil }
    let data = try Data(contentsOf: snapshotURL)
    let snapshot = try decoder.decode(MeshMapperSiriSnapshot.self, from: data)
    guard snapshot.version == Self.supportedVersion else {
      throw MeshMapperSiriSnapshotStoreError.unsupportedVersion(snapshot.version)
    }
    return snapshot
  }

  func clear() {
    guard let snapshotURL else { return }
    try? fileManager.removeItem(at: snapshotURL)
  }
}
