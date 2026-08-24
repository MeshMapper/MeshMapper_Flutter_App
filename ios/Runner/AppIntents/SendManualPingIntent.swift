import AppIntents

@available(iOS 26.0, *)
struct SendManualPingIntent: AppIntent {
  static let title: LocalizedStringResource = "Send MeshMapper Ping"
  static var authenticationPolicy: IntentAuthenticationPolicy {
    .requiresAuthentication
  }
  static var supportedModes: IntentModes { .foreground(.dynamic) }

  @MainActor
  func perform() async throws -> some IntentResult & ProvidesDialog {
    try await requestConfirmation(
      conditions: [],
      actionName: .send,
      dialog: "Send a MeshMapper radio ping?"
    )
    let result = try await SiriIntentCoordinator.shared.execute(
      SiriCommand(kind: .manualPing)
    )
    return .result(dialog: "\(result.message ?? "MeshMapper couldn't send a ping.")")
  }
}
