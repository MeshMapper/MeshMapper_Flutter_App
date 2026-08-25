import Flutter
import Foundation

enum SiriBridgeError: LocalizedError {
  case appUnavailable
  case timedOut(SiriCommand.Kind)
  case invalidResponse
  case flutter(String)

  var errorDescription: String? {
    switch self {
    case .appUnavailable:
      return "MeshMapper did not finish launching in time."
    case .timedOut(let kind):
      return kind.timeoutMessage
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

    /// What to say when the intent stops waiting for this kind.
    ///
    /// Only say "cancelled" where it is true. Start and Manual Ping are: Dart
    /// holds the same deadline and checks it immediately before every RF send,
    /// so nothing goes out and no session survives.
    ///
    /// The other two are best-effort by design and must not claim otherwise.
    /// Connecting cannot be called back once a transport is dialling, and a BLE
    /// GATT phase alone may run 15 seconds before protocol setup and
    /// authentication. Stopping is deliberately exempt from the deadline
    /// altogether — a safe-direction command must never be abandoned because a
    /// voice request timed out — and its teardown may queue a pending disable
    /// behind an RX window. Both overrun as a matter of course rather than
    /// exceptionally, so claiming cancellation would be a lie about as often as
    /// it was true.
    var timeoutMessage: String {
      switch self {
      case .startSession, .manualPing:
        return "MeshMapper took too long, so the request was cancelled."
      case .connectLastCompanion:
        return "MeshMapper didn't answer in time, and may still be connecting. Check the app in a moment."
      case .stopSession:
        return "MeshMapper didn't answer in time, and may still be stopping. Check the app in a moment."
      }
    }
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

  /// How long the intent waits for the real outcome before telling the person
  /// it failed. The same instant is handed to Dart as `expiresAtMs`, so giving
  /// up here and giving up there are one decision rather than two — for the
  /// session kinds. For `connectLastCompanion` it bounds the *response* only;
  /// see `Kind.timeoutMessage` for why, and for what is said instead.
  var responseTimeout: TimeInterval {
    kind == .connectLastCompanion ? 30 : 10
  }

  func dictionary(expiresAt: Date) -> [String: Any?] {
    [
      "id": id,
      "source": "siri",
      "kind": kind.rawValue,
      "issuedAtMs": Int64(issuedAt.timeIntervalSince1970 * 1_000),
      "expiresAtMs": Int64(expiresAt.timeIntervalSince1970 * 1_000),
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
      // Measured from here, not from the command's creation, because the wait
      // for the channel above can consume most of a cold launch on its own.
      let responseTimeout = command.responseTimeout
      let expiresAt = Date().addingTimeInterval(responseTimeout)
      let timeout = DispatchWorkItem {
        guard !completed else { return }
        completed = true
        continuation.resume(throwing: SiriBridgeError.timedOut(command.kind))
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
      channel.invokeMethod(
        "command",
        arguments: command.dictionary(expiresAt: expiresAt)
      ) { response in
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
