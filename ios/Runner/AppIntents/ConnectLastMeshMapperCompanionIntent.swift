import AppIntents

@available(iOS 26.0, *)
struct ConnectLastMeshMapperCompanionIntent: AppIntent {
  static let title: LocalizedStringResource = "Connect MeshMapper to Last Companion"
  static let description = IntentDescription(
    "Reconnects MeshMapper to the companion it most recently connected to."
  )
  static var authenticationPolicy: IntentAuthenticationPolicy {
    .requiresAuthentication
  }
  static var supportedModes: IntentModes { .foreground(.dynamic) }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let result = try await SiriIntentCoordinator.shared.execute(
      SiriCommand(kind: .connectLastCompanion)
    )
    let message = result.message ?? Self.fallback(for: result)
    return .result(value: message, dialog: "\(message)")
  }

  private static func fallback(for result: SiriCommandResult) -> String {
    switch result.disposition {
    case .admitted:
      return result.success
        ? "MeshMapper connected to its last companion."
        : "MeshMapper couldn't connect to its last companion."
    case .noOp:
      return "MeshMapper is already connected to its last companion."
    case .refused:
      return "MeshMapper couldn't connect to its last companion."
    }
  }
}
