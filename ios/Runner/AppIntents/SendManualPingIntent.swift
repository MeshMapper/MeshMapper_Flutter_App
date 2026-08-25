import AppIntents

@available(iOS 26.0, *)
struct SendManualPingIntent: AppIntent {
  static let title: LocalizedStringResource = "Send MeshMapper Ping"
  static var authenticationPolicy: IntentAuthenticationPolicy {
    .requiresAuthentication
  }
  static var supportedModes: IntentModes { .foreground(.dynamic) }

  @MainActor
  func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
    try await requestConfirmation(
      conditions: [],
      actionName: .send,
      dialog: "Send a MeshMapper radio ping?"
    )
    let result = try await SiriIntentCoordinator.shared.execute(
      SiriCommand(kind: .manualPing)
    )
    let message = result.message ?? "MeshMapper couldn't send a ping."
    return .result(value: message, dialog: "\(message)")
  }
}
