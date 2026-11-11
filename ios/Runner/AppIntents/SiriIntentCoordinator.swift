import AppIntents
import Flutter
import Foundation
import os

enum SiriBridgeError: LocalizedError {
  case appUnavailable
  case timedOut(SiriCommand.Kind)
  case invalidResponse
  case flutter(String)

  /// The single source for what the person is told, spoken and written alike.
  var message: String {
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

  var errorDescription: String? { message }
}

/// App Intents dialogs read `localizedStringResource`, not `errorDescription`.
/// Without this conformance every error thrown out of `perform()` reaches the
/// person as a generic system failure dialog instead of the reason above.
@available(iOS 16.0, *)
extension SiriBridgeError: CustomLocalizedStringResourceConvertible {
  var localizedStringResource: LocalizedStringResource {
    LocalizedStringResource(stringLiteral: message)
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
    /// altogether (a safe-direction command must never be abandoned because a
    /// voice request timed out), and its teardown may queue a pending disable
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
  /// up here and giving up there are one decision rather than two, for the
  /// session kinds. For `connectLastCompanion` it bounds the *response* only;
  /// see `Kind.timeoutMessage` for why, and for what is said instead.
  var responseTimeout: TimeInterval {
    kind == .connectLastCompanion ? 30 : 10
  }

  /// iOS ends an App Intent on its own 30 seconds after `perform()` starts and
  /// shows a generic failure ("an unknown error occurred" on iOS 26, a timeout
  /// on iOS 27), discarding whatever the intent returns after that. Every
  /// response deadline is capped at this much from the command's creation, so
  /// our own answer always lands first. Measured on device: `perform()` starts
  /// about 0.4 s into the run, and iOS cut the run at 30.01 s.
  static let intentBudget: TimeInterval = 25

  /// The instant the intent stops waiting: `responseTimeout` from now, but
  /// never past `intentBudget` from creation, since the channel wait before it
  /// already spent part of iOS's allowance.
  func responseDeadline(from now: Date = Date()) -> Date {
    min(
      now.addingTimeInterval(responseTimeout),
      issuedAt.addingTimeInterval(Self.intentBudget)
    )
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
  private let log = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MeshMapper",
    category: "Siri"
  )
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
    let kind = command.kind.rawValue
    let shortId = String(command.id.prefix(8))
    let channelWaitMs = Int(Date().timeIntervalSince(command.issuedAt) * 1_000)
    guard let channel else {
      log.error("\(kind, privacy: .public) \(shortId, privacy: .public): channel not ready after \(channelWaitMs)ms")
      throw SiriBridgeError.appUnavailable
    }

    let log = self.log
    return try await withCheckedThrowingContinuation { continuation in
      var completed = false
      // Measured from here, not from the command's creation, because the wait
      // for the channel above can consume most of a cold launch on its own,
      // then capped so it never outlives iOS's own limit on the intent.
      let sentAt = Date()
      let expiresAt = command.responseDeadline(from: sentAt)
      let responseTimeout = max(0, expiresAt.timeIntervalSince(sentAt))
      log.notice("\(kind, privacy: .public) \(shortId, privacy: .public): sent to Dart after \(channelWaitMs)ms channel wait, waiting \(Int(responseTimeout * 1_000))ms")
      let timeout = DispatchWorkItem {
        guard !completed else { return }
        completed = true
        log.error("\(kind, privacy: .public) \(shortId, privacy: .public): no answer from Dart within \(Int(responseTimeout * 1_000))ms")
        continuation.resume(throwing: SiriBridgeError.timedOut(command.kind))
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + responseTimeout, execute: timeout)
      channel.invokeMethod(
        "command",
        arguments: command.dictionary(expiresAt: expiresAt)
      ) { response in
        guard !completed else {
          log.notice("\(kind, privacy: .public) \(shortId, privacy: .public): late answer from Dart ignored")
          return
        }
        completed = true
        timeout.cancel()
        let elapsedMs = Int(Date().timeIntervalSince(sentAt) * 1_000)
        do {
          let result = try SiriCommandResult(response: response)
          log.notice("\(kind, privacy: .public) \(shortId, privacy: .public): answered in \(elapsedMs)ms, \(result.disposition.rawValue, privacy: .public) success=\(result.success)")
          continuation.resume(returning: result)
        } catch {
          log.error("\(kind, privacy: .public) \(shortId, privacy: .public): bad answer after \(elapsedMs)ms: \(error.localizedDescription, privacy: .public)")
          continuation.resume(throwing: error)
        }
      }
    }
  }
}
