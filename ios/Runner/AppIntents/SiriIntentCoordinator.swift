import Flutter
import Foundation

enum SiriBridgeError: LocalizedError {
  case appUnavailable
  case invalidResponse
  case flutter(String)

  var errorDescription: String? {
    switch self {
    case .appUnavailable:
      return "MeshMapper did not finish launching in time."
    case .invalidResponse:
      return "MeshMapper returned an invalid command result."
    case .flutter(let message):
      return message
    }
  }
}

struct SiriCommand {
  enum Kind: String {
    case startSession
    case stopSession
    case manualPing
    case connectLastCompanion
  }

  let id = UUID().uuidString
  let kind: Kind
  let mode: String?
  let sessionId: String?
  let issuedAt = Date()

  init(kind: Kind, mode: String? = nil, sessionId: String? = nil) {
    self.kind = kind
    self.mode = mode
    self.sessionId = sessionId
  }

  var dictionary: [String: Any?] {
    [
      "id": id,
      "source": "siri",
      "kind": kind.rawValue,
      "issuedAtMs": Int64(issuedAt.timeIntervalSince1970 * 1_000),
      "mode": mode,
      "sessionId": sessionId,
    ]
  }
}

struct SiriCommandResult {
  enum Disposition: String {
    case admitted
    case noOp
    case refused
  }

  let success: Bool
  let disposition: Disposition
  let message: String?
  let sessionId: String?
  let mode: String?

  init(response: Any?) throws {
    if let error = response as? FlutterError {
      throw SiriBridgeError.flutter(error.message ?? error.code)
    }
    guard let response = response as? [String: Any],
          let success = response["success"] as? Bool,
          let rawDisposition = response["disposition"] as? String,
          let disposition = Disposition(rawValue: rawDisposition)
    else {
      throw SiriBridgeError.invalidResponse
    }
    self.success = success
    self.disposition = disposition
    message = response["message"] as? String
    sessionId = response["sessionId"] as? String
    mode = response["mode"] as? String
  }
}

@MainActor
final class SiriIntentCoordinator {
  static let shared = SiriIntentCoordinator()

  private var channel: FlutterMethodChannel?
  private init() {}

  func attach(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func execute(_ command: SiriCommand) async throws -> SiriCommandResult {
    let deadline = Date().addingTimeInterval(10)
    while channel == nil, Date() < deadline {
      try Task.checkCancellation()
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    guard let channel else { throw SiriBridgeError.appUnavailable }

    return try await withCheckedThrowingContinuation { continuation in
      var completed = false
      let responseTimeout: TimeInterval = command.kind == .connectLastCompanion ? 30 : 10
      let timeout = DispatchWorkItem {
        guard !completed else { return }
        completed = true
        continuation.resume(throwing: SiriBridgeError.appUnavailable)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
      channel.invokeMethod("command", arguments: command.dictionary) { response in
        guard !completed else { return }
        completed = true
        timeout.cancel()
        do {
          continuation.resume(returning: try SiriCommandResult(response: response))
        } catch {
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
