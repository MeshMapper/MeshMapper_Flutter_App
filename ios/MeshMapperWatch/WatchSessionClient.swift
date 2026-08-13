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

  /// The phone's explanation for a refused admission or a later failed action.
  /// Both belong to one short-lived presentation path on the controls page.
  private(set) var lastRefusal: String?

  /// A refusal explains one completed tap, not the current transport state.
  /// Restarting its lifetime on replacement prevents an older expiry from
  /// erasing newer feedback that happens to arrive near the same moment.
  private var refusalExpiryTask: Task<Void, Never>?

  /// Immediate messages and application context can deliver the same cue in
  /// either order. IDs make that transport redelivery one visible event.
  private var presentedCueIDs = Set<String>()
  private var presentedCueIDOrder = [String]()

  /// Wearer-initiated command awaiting evidence of phone-side progress.
  /// Automatic refreshes stay out because they have no corresponding wrist
  /// action, and queued delivery has no acknowledgement to wait for.
  private(set) var pendingCommand: WatchCommand.Kind?
  private var pendingCommandTimeoutTask: Task<Void, Never>?

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
  /// Queues without pre-checking `isReachable`.
  ///
  /// Wrist controls normally run while the phone app is not foregrounded,
  /// where `sendMessage` can execute the command yet fail its reply as
  /// undeliverable. One queued path avoids both that false failure and the
  /// duplicate-transmit risk of retrying an ambiguously delivered message.
  func send(_ kind: WatchCommand.Kind, silent: Bool = false) {
    guard let session, session.activationState == .activated else {
      if !silent { setLastRefusal("Not connected to iPhone") }
      return
    }

    let command = WatchCommand(
      kind: kind,
      id: UUID().uuidString,
      issuedAtMs: Date().timeIntervalSince1970 * 1000
    )
    guard let data = try? MeshMapperWatchWire.encoder.encode(command),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      if !silent { setLastRefusal("Could not encode command") }
      return
    }

    if !silent {
      setLastRefusal(nil)
      beginPending(kind)
    }

    session.transferUserInfo([MeshMapperWatchWire.commandKey: dict])
  }

  private func beginPending(_ kind: WatchCommand.Kind) {
    pendingCommandTimeoutTask?.cancel()
    pendingCommand = kind
    pendingCommandTimeoutTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(10))
      guard !Task.isCancelled, self?.pendingCommand == kind else { return }
      self?.pendingCommand = nil
      self?.pendingCommandTimeoutTask = nil
    }
  }

  private func clearPendingCommand() {
    pendingCommandTimeoutTask?.cancel()
    pendingCommandTimeoutTask = nil
    pendingCommand = nil
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
      // A queued command has no ack. Any subsequent snapshot proves the phone
      // has resumed communicating; a separate timeout covers the case where
      // state dedupe means no snapshot follows.
      self.clearPendingCommand()

      if let cue = decoded.cue,
         self.presentedCueIDs.insert(cue.id).inserted
      {
        self.presentedCueIDOrder.append(cue.id)
        // The phone bounds its command-ID cache for the same reason: a watch
        // process can live for days, while only recent redelivery matters.
        if self.presentedCueIDOrder.count > 64 {
          self.presentedCueIDs.remove(self.presentedCueIDOrder.removeFirst())
        }
        if let message = cue.message, !message.isEmpty {
          self.setLastRefusal(message)
        }
      }
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
