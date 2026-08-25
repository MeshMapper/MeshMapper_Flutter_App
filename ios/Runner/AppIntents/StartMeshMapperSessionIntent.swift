import AppIntents

@available(iOS 26.0, *)
struct StartMeshMapperSessionIntent: AppIntent {
  static let title: LocalizedStringResource = "Start MeshMapper Session"
  static let description = IntentDescription(
    "Starts Active, Passive Discovery, or Hybrid mapping using MeshMapper's current radio policy."
  )
  static var authenticationPolicy: IntentAuthenticationPolicy {
    .requiresAuthentication
  }
  static var supportedModes: IntentModes { .foreground(.dynamic) }

  @Parameter(title: "Mode", default: .passive)
  var mode: MeshMapperSessionMode

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    let result = try await SiriIntentCoordinator.shared.execute(
      SiriCommand(kind: .startSession, mode: mode.rawValue)
    )
    let message = result.message ?? Self.fallback(for: result, mode: mode)
    return .result(
      value: message,
      dialog: "\(message)"
    )
  }

  private static func fallback(
    for result: SiriCommandResult,
    mode: MeshMapperSessionMode
  ) -> String {
    switch result.disposition {
    case .admitted:
      return result.success
        ? "MeshMapper started in \(mode.displayName) mode."
        : "MeshMapper couldn't start."
    case .noOp:
      return "MeshMapper is already running."
    case .refused:
      return "MeshMapper couldn't start."
    }
  }
}
