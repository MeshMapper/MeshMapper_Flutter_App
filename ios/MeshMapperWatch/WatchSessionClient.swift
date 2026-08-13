import Foundation
import SwiftUI
import WatchConnectivity

/// Receives snapshots from the iPhone and sends intents back.
///
/// The watch never decides anything: it renders what the phone sent and asks
/// for what the wearer tapped. The phone owns the BLE link, the GPS fix, and
/// every guard around transmitting.
@Observable
final class WatchSessionClient: NSObject {
  /// Latest state from the phone, or nil before the first delivery.
  private(set) var snapshot: WatchSnapshot?

  /// When the last snapshot arrived — drives the stale badge.
  private(set) var receivedAt: Date?

  /// Set when the phone refuses a command, so the wrist can say why.
  private(set) var lastRefusal: String?

  /// A refusal explains one completed tap, not the current transport state.
  /// Restarting its lifetime on replacement prevents an older expiry from
  /// erasing newer feedback that happens to arrive near the same moment.
  private var refusalExpiryTask: Task<Void, Never>?

  /// Wearer-initiated command awaiting the phone's answer. Automatic refreshes
  /// stay out of this state because they have no corresponding wrist action.
  private(set) var pendingCommand: WatchCommand.Kind?

  /// Set when a payload arrives from a wire version this build predates.
  private(set) var versionMismatch = false

  private var session: WCSession? {
    WCSession.isSupported() ? WCSession.default : nil
  }

  var isReachable: Bool { session?.isReachable ?? false }

  /// A snapshot older than this is shown greyed with an age badge. The phone
  /// only sends on real change, so silence is normal — this threshold is
  /// about "the phone has probably gone away", not "no update recently".
  static let staleAfter: TimeInterval = 90

  var isStale: Bool {
    guard let receivedAt else { return true }
    return Date().timeIntervalSince(receivedAt) > Self.staleAfter
  }

  /// Bring the session up and pull a current snapshot.
  ///
  /// Activation is asynchronous, so a refresh requested before it completes is
  /// deferred to the activation callback rather than failing as "unreachable".
  func refresh() {
    #if DEBUG
    if SampleSnapshot.isEnabled {
      snapshot = SampleSnapshot.make()
      receivedAt = Date()
      return
    }
    #endif

    guard let session else { return }
    session.delegate = self

    if session.activationState == .activated {
      ingest(context: session.receivedApplicationContext)
      send(.requestSnapshot, silent: true)
      return
    }

    pendingRefresh = true
    session.activate()
  }

  private var pendingRefresh = false

  // MARK: - Commands

  /// - Parameter silent: suppress the refusal banner. Used for the automatic
  ///   refresh, which the wearer never asked for and shouldn't see fail.
  /// Sends without pre-checking `isReachable`.
  ///
  /// That flag lags reality — during testing the simulator reported
  /// unreachable while messages were still being delivered a second or two
  /// later. Gating on it turns a stale flag into a refused tap, so the send is
  /// attempted unconditionally and `errorHandler` is the source of truth.
  func send(_ kind: WatchCommand.Kind, silent: Bool = false) {
    guard let session, session.activationState == .activated else {
      if !silent { setLastRefusal("Not connected to iPhone") }
      return
    }

    let command = WatchCommand(kind: kind, id: UUID().uuidString)
    guard let data = try? MeshMapperWatchWire.encoder.encode(command),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      if !silent { setLastRefusal("Could not encode command") }
      return
    }

    if !silent {
      setLastRefusal(nil)
      pendingCommand = kind
    }

    session.sendMessage(
      [MeshMapperWatchWire.commandKey: dict],
      replyHandler: { [weak self] reply in
        NSLog("[WATCH] reply for \(kind.rawValue): \(reply)")
        Task { @MainActor in
          let isCurrent = self?.pendingCommand == kind
          if isCurrent {
            self?.pendingCommand = nil
          }
          // A newer tap owns both the spinner and its feedback. Letting an
          // older reply rewrite either would put the wrong answer under it.
          guard !silent, isCurrent else { return }
          let accepted = reply["accepted"] as? Bool ?? false
          if accepted {
            self?.setLastRefusal(nil)
          } else {
            // The phone owns the policy and already phrases its refusals for
            // people; preserving that text avoids replacing fact with a watch
            // side guess about why the command was rejected.
            self?.setLastRefusal(reply["reason"] as? String ?? "Refused")
          }
        }
      },
      errorHandler: { [weak self] error in
        NSLog("[WATCH] sendMessage(\(kind.rawValue)) failed: \(error.localizedDescription)")
        Task { @MainActor in
          let isCurrent = self?.pendingCommand == kind
          if isCurrent {
            self?.pendingCommand = nil
          }
          if !silent, isCurrent {
            self?.setLastRefusal(Self.refusalMessage(for: error))
          }
        }
      }
    )
  }

  private func setLastRefusal(_ refusal: String?) {
    refusalExpiryTask?.cancel()
    refusalExpiryTask = nil
    lastRefusal = refusal

    guard refusal != nil else { return }
    refusalExpiryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      self?.lastRefusal = nil
      self?.refusalExpiryTask = nil
    }
  }

  private static func refusalMessage(for error: Error) -> String {
    let nsError = error as NSError
    guard nsError.domain == WCErrorDomain,
          let code = WCError.Code(rawValue: nsError.code)
    else {
      return error.localizedDescription
    }

    switch code {
      case .deliveryFailed, .notReachable:
        // Delivery is uncertain in both cases. Give the wearer one useful next
        // step, but never retry automatically: a duplicate could transmit.
        return "iPhone didn't respond, try again"
      default:
        return error.localizedDescription
    }
  }

  // MARK: - Ingest

  private func ingest(context: [String: Any]) {
    guard let data = context[MeshMapperWatchWire.payloadKey] as? Data else { return }
    ingest(data: data)
  }

  private func ingest(data: Data) {
    guard let decoded = try? MeshMapperWatchWire.decoder.decode(WatchSnapshot.self, from: data)
    else {
      return
    }

    // Refuse rather than render a payload whose fields may have changed
    // meaning — a wrong reading on the wrist is worse than a blank one.
    guard decoded.isSupportedVersion else {
      Task { @MainActor in self.versionMismatch = true }
      return
    }

    Task { @MainActor in
      self.versionMismatch = false
      self.snapshot = decoded
      self.receivedAt = Date()
    }
  }
}

// MARK: - WCSessionDelegate

extension WatchSessionClient: WCSessionDelegate {
  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if activationState == .activated {
      ingest(context: session.receivedApplicationContext)
      if pendingRefresh {
        pendingRefresh = false
        send(.requestSnapshot, silent: true)
      }
    }
  }

  func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
    ingest(context: applicationContext)
  }

  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    guard let data = message[MeshMapperWatchWire.payloadKey] as? Data else { return }
    ingest(data: data)
  }
}
