import AppIntents

@available(iOS 26.0, *)
struct StopMeshMapperSessionIntent: AppIntent {
  static let title: LocalizedStringResource = "Stop MeshMapper Session"
  static var authenticationPolicy: IntentAuthenticationPolicy { .alwaysAllowed }
  static var supportedModes: IntentModes {
    [.background, .foreground(.dynamic)]
  }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    // The snapshot is an optimization, never authority for the safe-direction
    // Stop command. A missing, stale, corrupt, or newer snapshot must not keep
    // a live radio session running. Bind to an ID only when the cache says a
    // session exists; otherwise let Dart resolve the current session.
    let snapshot = try? MeshMapperSiriSnapshotStore.shared.read()
    let sessionId: String?
    if let snapshot, snapshot.session.active || snapshot.session.starting {
      sessionId = snapshot.session.id
    } else {
      sessionId = nil
    }
    let result = try await SiriIntentCoordinator.shared.execute(
      SiriCommand(kind: .stopSession, sessionId: sessionId)
    )
    let message = result.message ?? "MeshMapper couldn't stop."
    return .result(value: message, dialog: "\(message)")
  }
}
