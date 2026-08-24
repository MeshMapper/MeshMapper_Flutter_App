import AppIntents

@available(iOS 26.0, *)
struct StopMeshMapperSessionIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop MeshMapper Session"
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
  static var supportedModes: IntentModes {
    [.background, .foreground(.dynamic)]
  }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    guard let snapshot = try MeshMapperSiriSnapshotStore.shared.read(),
          snapshot.session.active || snapshot.session.starting
    else {
      return .result(dialog: "MeshMapper is already stopped.")
    }
    let result = try await SiriIntentCoordinator.shared.execute(
      SiriCommand(kind: .stopSession, sessionId: snapshot.session.id)
    )
    return .result(dialog: "\(result.message ?? "MeshMapper couldn't stop.")")
  }
}
