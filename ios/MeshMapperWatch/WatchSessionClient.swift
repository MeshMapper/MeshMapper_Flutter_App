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

  /// Stored rather than derived from `Date()`: time passing does not invalidate
  /// a SwiftUI observation by itself, so the boundary has to become an event.
  private(set) var isStale = true
  private var staleBoundaryTask: Task<Void, Never>?

  /// The phone's explanation for a refused admission or a later failed action.
  /// Both belong to one short-lived presentation path on the controls page.
  private(set) var lastRefusal: String?

  /// Explicit attribution lets Controls place feedback beside the action it
  /// explains without guessing that an unrelated phone event belongs to the
  /// last thing tapped. It never affects admission, transport, or the command.
  private(set) var lastRefusalCommand: WatchCommand.Kind?

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

  /// Whether the currently rendered surface needs map-only geography.
  /// Launches begin true: an unnecessary full payload is preferable to a map
  /// that opens blank before this process has described its current surface.
  private var mapGeoNeeded = true
  private var lastSentMapGeoNeeded: Bool?
  private var mapGeoSuppressionTask: Task<Void, Never>?
  private var mapGeoRenewalTask: Task<Void, Never>?
  private var lastMapGeoRecoveryRequestAt: Date?

  private var session: WCSession? {
    WCSession.isSupported() ? WCSession.default : nil
  }

  var isReachable: Bool { session?.isReachable ?? false }

  /// A snapshot older than this is shown greyed with an age badge. The phone
  /// only sends on real change, so silence is normal — this threshold is
  /// about "the phone has probably gone away", not "no update recently".
  static let staleAfter: TimeInterval = 90
  private static let cueFreshFor: TimeInterval = 30
  /// Phone and watch clocks normally agree to well under a second. This is the
  /// slack allowed anywhere a phone-stamped time is compared against watch
  /// "now", and mirrors the tolerance the phone applies to watch commands.
  private static let clockTolerance: TimeInterval = 5
  private static let mapGeoSuppressionDelay: TimeInterval = 15
  private static let mapGeoRenewalInterval: TimeInterval = 5 * 60
  private static let mapGeoRecoveryThrottle: TimeInterval = 3

  /// Bring the session up and pull a current snapshot.
  ///
  /// Activation is asynchronous, so a refresh requested before it completes is
  /// deferred to the activation callback rather than failing as "unreachable".
  func refresh() {
    #if DEBUG
    if SampleSnapshot.isEnabled {
      snapshot = SampleSnapshot.make()
      markSnapshotReceived()
      return
    }
    #endif

    guard let session else { return }
    session.delegate = self

    if session.activationState == .activated {
      ingest(context: session.receivedApplicationContext)
      requestFullSnapshot()
      if !mapGeoNeeded { scheduleMapGeoSuppression() }
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
  func send(
    _ kind: WatchCommand.Kind,
    mode: String? = nil,
    mapGeoNeeded: Bool? = nil,
    silent: Bool = false
  ) {
    guard let session, session.activationState == .activated else {
      if !silent {
        setLastRefusal("Not connected to iPhone", from: kind)
      }
      return
    }

    let command = WatchCommand(
      kind: kind,
      mode: mode,
      mapGeoNeeded: mapGeoNeeded,
      id: UUID().uuidString,
      issuedAtMs: Date().timeIntervalSince1970 * 1000
    )
    guard let data = try? MeshMapperWatchWire.encoder.encode(command),
          let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
      if !silent {
        setLastRefusal("Could not encode command", from: kind)
      }
      return
    }

    if !silent {
      setLastRefusal(nil, from: kind)
      beginPending(kind)
    }

    session.transferUserInfo([MeshMapperWatchWire.commandKey: dict])
  }

  /// Report whether the current surface needs its expensive marker payload.
  /// Returning to the map is immediate; suppression waits out short wrist-down
  /// transitions so ordinary glances do not enqueue a false/true pair.
  func setMapGeoNeeded(_ needed: Bool) {
    mapGeoNeeded = needed
    mapGeoSuppressionTask?.cancel()
    mapGeoSuppressionTask = nil

    if needed {
      mapGeoRenewalTask?.cancel()
      mapGeoRenewalTask = nil
      sendMapGeoPreference(true)
    } else {
      scheduleMapGeoSuppression()
    }
  }

  private func scheduleMapGeoSuppression() {
    mapGeoSuppressionTask?.cancel()
    mapGeoSuppressionTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.mapGeoSuppressionDelay))
      guard !Task.isCancelled, let self, !self.mapGeoNeeded else { return }
      self.mapGeoSuppressionTask = nil
      self.sendMapGeoPreference(false)
      self.scheduleMapGeoRenewal()
    }
  }

  private func scheduleMapGeoRenewal() {
    mapGeoRenewalTask?.cancel()
    mapGeoRenewalTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(Self.mapGeoRenewalInterval))
      guard !Task.isCancelled, let self, !self.mapGeoNeeded else { return }
      self.mapGeoRenewalTask = nil
      // The phone treats suppression as a lease. Renewal keeps a long
      // Always-On session cheap; if this task stops, the lease expires back
      // to full geography rather than leaving a future map blank.
      self.sendMapGeoPreference(false, force: true)
      self.scheduleMapGeoRenewal()
    }
  }

  private func sendMapGeoPreference(_ needed: Bool, force: Bool = false) {
    guard force || lastSentMapGeoNeeded != needed else { return }
    guard let session, session.activationState == .activated else { return }
    lastSentMapGeoNeeded = needed
    send(.requestSnapshot, mapGeoNeeded: needed, silent: true)
  }

  private func requestFullSnapshot() {
    // Activation always starts from the safe assumption even if a retained
    // application context says the previous process had suppressed its map.
    sendMapGeoPreference(true, force: true)
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

  #if DEBUG
  /// Seed a refusal so the failure banner can be captured headlessly.
  ///
  /// The banner is otherwise unreachable in the simulator: producing one needs
  /// a command to be refused, and there is no way to tap a control there. It
  /// expires on the usual six-second schedule, so a capture must be taken
  /// inside that window — a screenshot at eight seconds shows an empty screen
  /// and reads exactly like a broken banner.
  func debugForceRefusal(_ message: String) {
    setLastRefusal(message, from: .startSession)
  }
  #endif

  private func setLastRefusal(
    _ refusal: String?,
    from command: WatchCommand.Kind?
  ) {
    refusalExpiryTask?.cancel()
    refusalExpiryTask = nil
    lastRefusal = refusal
    lastRefusalCommand = refusal == nil ? nil : command

    guard refusal != nil else { return }
    refusalExpiryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(6))
      guard !Task.isCancelled else { return }
      self?.lastRefusal = nil
      self?.lastRefusalCommand = nil
      self?.refusalExpiryTask = nil
    }
  }

  /// - Parameter producedAt: when the phone built the payload. Absent for the
  ///   debug sample, which is generated on the wrist.
  private func markSnapshotReceived(at arrival: Date = Date(), producedAt: Date? = nil) {
    staleBoundaryTask?.cancel()
    staleBoundaryTask = nil

    // Age from when the phone built the payload rather than when it reached the
    // wrist. Launch ingests whatever application context WatchConnectivity
    // retained, which can be hours old, and stamping arrival there would
    // present long-dead state as fresh for a full 90 seconds.
    //
    // Clamped to `arrival` so a phone clock running fast cannot date a snapshot
    // into the future and extend its life, with a few seconds of slack so
    // ordinary skew does not age a genuinely live payload early.
    let origin =
      producedAt.map { min(arrival, $0.addingTimeInterval(Self.clockTolerance)) } ?? arrival
    receivedAt = origin

    let remaining = Self.staleAfter - arrival.timeIntervalSince(origin)
    guard remaining > 0 else {
      isStale = true
      return
    }
    isStale = false

    // One task per delivery makes the 90-second boundary observable without a
    // polling timer. A newer snapshot cancels this task and owns the next one.
    staleBoundaryTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: .seconds(remaining))
      guard !Task.isCancelled, self?.receivedAt == origin else { return }
      self?.isStale = true
      self?.staleBoundaryTask = nil
    }
  }

  private static func isFresh(_ cue: WatchHapticCue, at arrival: Date) -> Bool {
    guard let issuedAt = cue.issuedAt else { return false }
    let age = arrival.timeIntervalSince(issuedAt)
    // A few seconds of skew must not suppress a real failure that has just
    // crossed the radio.
    return age >= -clockTolerance && age <= cueFreshFor
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
      let arrival = Date()
      self.versionMismatch = false
      self.snapshot = decoded
      self.markSnapshotReceived(at: arrival, producedAt: decoded.updatedAt)
      // A queued command has no ack. Any subsequent snapshot proves the phone
      // has resumed communicating; a separate timeout covers the case where
      // state dedupe means no snapshot follows.
      self.clearPendingCommand()

      if self.mapGeoNeeded && !decoded.mapGeoIncluded {
        // updateApplicationContext is latest-state-wins, but a context sent
        // just before the map reappeared may still win the delivery race. The
        // empty arrays are rendered honestly, then a full replacement is
        // requested immediately rather than mixing old markers with new state.
        let lastRequest = self.lastMapGeoRecoveryRequestAt
        if lastRequest == nil ||
            arrival.timeIntervalSince(lastRequest ?? .distantPast) >=
              Self.mapGeoRecoveryThrottle
        {
          self.lastMapGeoRecoveryRequestAt = arrival
          self.sendMapGeoPreference(true, force: true)
        }
      }

      if let cue = decoded.cue,
         Self.isFresh(cue, at: arrival),
         self.presentedCueIDs.insert(cue.id).inserted
      {
        self.presentedCueIDOrder.append(cue.id)
        // The phone bounds its command-ID cache for the same reason: a watch
        // process can live for days, while only recent redelivery matters.
        if self.presentedCueIDOrder.count > 64 {
          self.presentedCueIDs.remove(self.presentedCueIDOrder.removeFirst())
        }
        if let message = cue.message, !message.isEmpty {
          // A cue may be a late wrist-command failure or an unrelated phone
          // event; the current wire cannot distinguish them, so attribution
          // here would be a guess. Correlating it later requires carrying the
          // originating command on `WatchHapticCue` across the wire.
          self.setLastRefusal(message, from: nil)
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
        requestFullSnapshot()
        if !mapGeoNeeded { scheduleMapGeoSuppression() }
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
