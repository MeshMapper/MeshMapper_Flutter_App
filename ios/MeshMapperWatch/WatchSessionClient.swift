import Foundation
import SwiftUI
import WatchConnectivity
import WatchKit

/// Receives snapshots from the iPhone and sends intents back.
///
/// The watch never decides anything: it renders what the phone sent and asks
/// for what the wearer tapped. The phone owns the BLE link, the GPS fix, and
/// every guard around transmitting.
///
/// **Main-actor isolated, because everything it stores is rendered.**
/// WatchConnectivity documents that "the methods of this protocol are called on
/// a background thread of your app", and every stored property here is read by
/// SwiftUI through `@Observable`. The delegate conformance below is therefore
/// `nonisolated` and hops explicitly; see the note on the extension for what
/// deliberately stays off the main actor.
@Observable
@MainActor
final class WatchSessionClient: NSObject {
  /// Read for exactly one decision: whether a cue may play a haptic.
  ///
  /// Held rather than resolved from `UserDefaults` here so the preference has
  /// one owner. Two surfaces resolving the same preference independently is
  /// the failure `effectiveStartMode` exists to prevent, and a silenced watch
  /// that still buzzes would be the same class of bug.
  @ObservationIgnored private let settings: WatchSettings

  init(settings: WatchSettings) {
    self.settings = settings
    super.init()
  }

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

  /// Mirrors `WCSession.isReachable`, stored rather than computed.
  ///
  /// Reading `WCSession.default.isReachable` inside a computed property takes
  /// no observation dependency, so a view rendering it was never invalidated
  /// when reachability changed — it showed whatever happened to be true at the
  /// last unrelated render. `sessionReachabilityDidChange` is the callback that
  /// turns the change into an event, exactly as its documentation intends.
  private(set) var isReachable = false

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
      startSampleWalkIfRequested()
      return
    }
    #endif

    guard let session else { return }
    session.delegate = self

    if session.activationState == .activated {
      // An already-activated session fires no activation callback, so this is
      // the only chance to seed reachability before the first render.
      noteReachability(session.isReachable)
      ingest(context: session.receivedApplicationContext)
      requestFullSnapshot()
      if !mapGeoNeeded { scheduleMapGeoSuppression() }
      return
    }

    pendingRefresh = true
    session.activate()
  }

  /// Reconcile after the scene becomes active again.
  ///
  /// `onAppear` is not a resume callback — it fires once — and watchOS suspends
  /// this app for essentially the whole wrist-down interval, measured here at
  /// 7.42 s of suspension against 8.20 s of wrist-down. So without this a
  /// wearer could raise their wrist onto state the UI itself calls stale and
  /// have nothing ask the phone to prove otherwise.
  ///
  /// Deliberately not `refresh()`. That always requests, which would put a
  /// WatchConnectivity round trip behind every glance — the opposite of what
  /// this transport is built for. Ingesting the retained context is free, so
  /// do it always; spend the radio only when what we hold is stale or missing,
  /// which is exactly when a request can change what the wearer sees.
  func resume() {
    #if DEBUG
    if SampleSnapshot.isEnabled { return }
    #endif

    guard let session else { return }
    session.delegate = self

    guard session.activationState == .activated else {
      pendingRefresh = true
      session.activate()
      return
    }

    // A reachability change during the suspension has no delegate callback to
    // deliver, so re-read it alongside the retained context.
    noteReachability(session.isReachable)

    // Applied synchronously, unlike every other ingest. The queued variant
    // lands after this method returns, so the decision below was made against
    // pre-resume state — and the 90 s staleness flip inside `apply` is queued
    // the same way. Whichever way main-actor ordering happened to fall, one of
    // the two failures this method exists to prevent came back: a `forceRefresh`
    // full snapshot on every glance past the boundary despite holding a
    // seconds-old context, or a wearer left looking at stale UI.
    ingestNow(context: session.receivedApplicationContext)

    // Read after ingesting: a context retained while the wrist was down may
    // have just answered the question, and then the radio is not needed.
    let needsPhone = snapshot == nil || isStale
    #if DEBUG
    // The whole claim of this method in one line per glance. A wrist-raise run
    // should show `resume-local` for fresh glances and exactly one
    // `resume-request` for the first glance past the stale boundary.
    WakeLog.note(needsPhone ? "resume-request" : "resume-local")
    #endif
    if needsPhone { requestFullSnapshot() }

    if !mapGeoNeeded { scheduleMapGeoSuppression() }
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
    forceRefresh: Bool = false,
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
      forceRefresh: forceRefresh ? true : nil,
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

  /// - Parameter force: resend even when the phone was already told this value,
  ///   which is what renews the lease.
  /// - Parameter refresh: additionally demand a snapshot back. Lease traffic
  ///   leaves this false so an unchanged session stays silent.
  private func sendMapGeoPreference(
    _ needed: Bool,
    force: Bool = false,
    refresh: Bool = false
  ) {
    guard force || lastSentMapGeoNeeded != needed else { return }
    guard let session, session.activationState == .activated else { return }
    lastSentMapGeoNeeded = needed
    send(
      .requestSnapshot,
      mapGeoNeeded: needed,
      forceRefresh: refresh,
      silent: true
    )
  }

  private func requestFullSnapshot() {
    // Activation always starts from the safe assumption even if a retained
    // application context says the previous process had suppressed its map.
    //
    // This is the one caller that genuinely needs state back: whatever the
    // watch holds came from a retained context of unknown age, so an unchanged
    // session must still answer rather than dedupe into silence.
    sendMapGeoPreference(true, force: true, refresh: true)
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

  /// The main-actor half of the activation callback.
  private func completeActivation() {
    guard pendingRefresh else { return }
    pendingRefresh = false
    requestFullSnapshot()
    if !mapGeoNeeded { scheduleMapGeoSuppression() }
  }

  private func noteReachability(_ reachable: Bool) {
    guard isReachable != reachable else { return }
    isReachable = reachable
  }

  #if DEBUG
  /// Advance the sample fix so the follow camera has something to track.
  ///
  /// The stationary sample snapshot can show that the map *renders*, never that
  /// it moves well — and motion is the one thing the follow animation exists
  /// for. This walks the fix at the real wire's step size and cadence rather
  /// than smoothly, because a continuous feed would hide exactly the jump being
  /// smoothed.
  ///
  /// Idempotent: `refresh()` runs on every scene activation and must not leave
  /// a second walker behind, which would double the pace.
  private func startSampleWalkIfRequested() {
    guard sampleWalkTask == nil, SampleSnapshot.isWalking else { return }

    let interval = SampleSnapshot.walkStepInterval
    sampleWalkTask = Task { @MainActor [weak self] in
      var steps = 0
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(interval))
        guard !Task.isCancelled, let self else { return }
        steps += 1
        self.snapshot = SampleSnapshot.make(stepsWalked: steps)
        self.markSnapshotReceived()
      }
    }
  }

  /// Not observed: nothing renders the walker, and letting it invalidate views
  /// would make the harness a source of the redraws it is meant to measure.
  @ObservationIgnored private var sampleWalkTask: Task<Void, Never>?
  #endif

  /// Let the wearer feel a cue the phone raised.
  ///
  /// **This only fires while watchOS is actually running this app.** The system
  /// ignores `play(_:)` from a suspended or background app, so a failure that
  /// lands during a long wrist-down is still seen rather than felt. The case it
  /// answers is the real one: a wearer taps Ping or Start, gets an accepted
  /// ack, glances away, and the command fails a moment later with the app
  /// still frontmost. Before this the only report was a banner on a screen the
  /// wearer had stopped reading.
  ///
  /// Unknown kinds still play. The wire calls this "a one-shot event the watch
  /// should feel", so an older watch meeting a newer phone should err toward
  /// the generic notification rather than toward silence.
  private func play(_ cue: WatchHapticCue) {
    guard settings.haptics else { return }
    let type: WKHapticType
    switch cue.kind {
    case "success": type = .success
    case "failure": type = .failure
    default: type = .notification
    }
    WKInterfaceDevice.current().play(type)
  }

  // MARK: - Ingest

  /// What a delivered payload turned out to be.
  private enum Ingested {
    case snapshot(WatchSnapshot)
    case unsupportedVersion
    case undecodable
  }

  /// Just the version, so it can be read from a payload the full model cannot
  /// decode.
  ///
  /// `WatchSnapshot` decodes its required fields with a throwing decoder, so a
  /// future wire that removes or renames one — a documented reason to bump
  /// `MeshMapperWatchWire.version` — fails to decode before the version is ever
  /// examined. That is precisely the case the refusal exists for: without this
  /// the watch would silently drop every payload and go permanently stale
  /// instead of telling the wearer to update the iPhone app.
  private struct WireVersionProbe: Decodable {
    let wireVersion: Int
  }

  private nonisolated static func decode(_ data: Data) -> Ingested {
    let decoder = MeshMapperWatchWire.decoder
    guard let probe = try? decoder.decode(WireVersionProbe.self, from: data) else {
      return .undecodable
    }
    // Refuse rather than render a payload whose fields may have changed
    // meaning — a wrong reading on the wrist is worse than a blank one.
    guard probe.wireVersion == MeshMapperWatchWire.version else {
      return .unsupportedVersion
    }
    guard let decoded = try? decoder.decode(WatchSnapshot.self, from: data) else {
      return .undecodable
    }
    return .snapshot(decoded)
  }

  /// `nonisolated` on purpose: decoding is the expensive part, it needs no
  /// isolation, and WatchConnectivity already hands it to us on a background
  /// thread. Only `apply` crosses onto the main actor.
  private nonisolated func ingest(context: [String: Any]) {
    guard let data = context[MeshMapperWatchWire.payloadKey] as? Data else { return }
    ingest(data: data)
  }

  private nonisolated func ingest(data: Data) {
    switch Self.decode(data) {
    case .undecodable:
      return
    case .unsupportedVersion:
      Task { @MainActor [weak self] in self?.versionMismatch = true }
    case .snapshot(let decoded):
      Task { @MainActor [weak self] in self?.apply(decoded) }
    }
  }

  /// Ingest without the main-actor hop, for a caller that has to see the result
  /// before it can decide anything.
  ///
  /// The asynchronous path above is the right default — a 12 kB parse does not
  /// belong on the wrist's main thread on every snapshot. This one runs once
  /// per wrist raise, where the alternative is deciding whether to spend the
  /// radio against state the queued apply has not delivered yet.
  private func ingestNow(context: [String: Any]) {
    guard let data = context[MeshMapperWatchWire.payloadKey] as? Data else { return }
    switch Self.decode(data) {
    case .undecodable:
      return
    case .unsupportedVersion:
      versionMismatch = true
    case .snapshot(let decoded):
      apply(decoded)
    }
  }

  private func apply(_ decoded: WatchSnapshot) {
    let arrival = Date()
    versionMismatch = false
    snapshot = decoded
    markSnapshotReceived(at: arrival, producedAt: decoded.updatedAt)
    // A queued command has no ack. Any subsequent snapshot proves the phone
    // has resumed communicating; a separate timeout covers the case where
    // state dedupe means no snapshot follows.
    clearPendingCommand()

    if mapGeoNeeded && !decoded.mapGeoIncluded {
      // updateApplicationContext is latest-state-wins, but a context sent
      // just before the map reappeared may still win the delivery race. The
      // empty arrays are rendered honestly, then a full replacement is
      // requested immediately rather than mixing old markers with new state.
      let lastRequest = lastMapGeoRecoveryRequestAt
      if lastRequest == nil ||
          arrival.timeIntervalSince(lastRequest ?? .distantPast) >=
            Self.mapGeoRecoveryThrottle
      {
        lastMapGeoRecoveryRequestAt = arrival
        sendMapGeoPreference(true, force: true)
      }
    }

    if let cue = decoded.cue,
       Self.isFresh(cue, at: arrival),
       presentedCueIDs.insert(cue.id).inserted
    {
      presentedCueIDOrder.append(cue.id)
      // The phone bounds its command-ID cache for the same reason: a watch
      // process can live for days, while only recent redelivery matters.
      if presentedCueIDOrder.count > 64 {
        presentedCueIDs.remove(presentedCueIDOrder.removeFirst())
      }
      // Played here rather than from a view: this branch is already the one
      // place that decides a cue is new, fresh, and worth presenting. A view
      // would have to re-derive that gate from exported state and would get
      // it wrong on redelivery, which WatchConnectivity does routinely.
      play(cue)
      if let message = cue.message, !message.isEmpty {
        // A cue may be a late wrist-command failure or an unrelated phone
        // event; the current wire cannot distinguish them, so attribution
        // here would be a guess. Correlating it later requires carrying the
        // originating command on `WatchHapticCue` across the wire.
        setLastRefusal(message, from: nil)
      }
    }
  }
}

// MARK: - WCSessionDelegate

/// Every method here is `nonisolated`, because WatchConnectivity documents that
/// "the methods of this protocol are called on a background thread of your app"
/// and asks that any resulting interface change be redirected to the main
/// thread. `ingest` was already doing that for the payload; the activation path
/// was not, and reached `pendingRefresh`, `lastSentMapGeoNeeded` and
/// `mapGeoSuppressionTask` — all `@Observable`-tracked and all read on the main
/// actor — straight from the delivery queue.
///
/// Decoding stays off the main actor deliberately. It is the only expensive
/// thing that happens here, it touches no state, and pushing a 12 kB JSON parse
/// onto the wrist's main thread on every snapshot would trade one defect for a
/// worse one.
extension WatchSessionClient: WCSessionDelegate {
  nonisolated func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    guard activationState == .activated else { return }
    ingest(context: session.receivedApplicationContext)
    let reachable = session.isReachable
    Task { @MainActor [weak self] in
      self?.noteReachability(reachable)
      self?.completeActivation()
    }
  }

  nonisolated func session(
    _ session: WCSession,
    didReceiveApplicationContext applicationContext: [String: Any]
  ) {
    ingest(context: applicationContext)
  }

  nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    guard let data = message[MeshMapperWatchWire.payloadKey] as? Data else { return }
    ingest(data: data)
  }

  /// The documented signal for `isReachable` changing. Without it the property
  /// is only ever as current as the last activation.
  nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
    let reachable = session.isReachable
    Task { @MainActor [weak self] in self?.noteReachability(reachable) }
  }
}
