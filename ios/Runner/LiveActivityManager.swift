import ActivityKit
import Flutter
import Foundation

/// Native ActivityKit endpoint for the Flutter method channel.
///
/// Flutter sends complete snapshots. The manager keeps at most one activity,
/// updates it serially, and doesn't recreate a Live Activity the user dismissed
/// during the same wardriving session.
/// Sentinels shared with the Dart side of the channel.
enum MeshMapperLiveActivityStatus {
  /// This OS cannot host a Live Activity at all, at any point in this session.
  static let unsupported = "unsupported"
}

final class LiveActivityManager {
  private enum BridgeError: LocalizedError {
    case invalidArguments

    var errorDescription: String? {
      "The Live Activity payload was invalid."
    }
  }

  private var requestedSessionID: String?

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sync":
      guard let payload = call.arguments as? [String: Any] else {
        result(flutterError(BridgeError.invalidArguments, code: "invalid_arguments"))
        return
      }
      // Distinct from `false`, which means "not right now" and earns a retry.
      // This host will never gain ActivityKit, so a retry loop for the life of
      // every session is pure waste; Dart stops asking for good.
      guard #available(iOS 16.2, *) else {
        result(MeshMapperLiveActivityStatus.unsupported)
        return
      }
      // Genuinely "not right now": the wearer can enable Live Activities in
      // Settings while a session is running, so this one keeps its backoff.
      guard ActivityAuthorizationInfo().areActivitiesEnabled else {
        result(false)
        return
      }

      Task { @MainActor in
        do {
          let parsed = try parse(payload)
          try await sync(attributes: parsed.attributes, state: parsed.state)
          result(true)
        } catch ActivityAuthorizationError.visibility {
          // ActivityKit only permits `request` from a foreground app, and a
          // session can begin backgrounded — auto-ping is restored after a BLE
          // auto-reconnect under the background service. Reported as an error
          // this bypassed Dart's 30 s backoff, which only arms on a `false`
          // result, so every throttled sync retried and logged a failure for as
          // long as the app stayed in the background. `false` is the honest
          // answer anyway: there is nowhere to put an activity right now.
          NSLog("[LIVE ACTIVITY] Cannot start while backgrounded; will retry")
          result(false)
        } catch {
          result(self.flutterError(error, code: "sync_failed"))
        }
      }

    case "end":
      guard #available(iOS 16.2, *) else {
        result(nil)
        return
      }
      let immediate =
        (call.arguments as? [String: Any])?["immediate"] as? Bool ?? false
      Task { @MainActor in
        await endAll(keepSummaryFor: immediate ? 0 : 60)
        requestedSessionID = nil
        result(nil)
      }

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func flutterError(_ error: Error, code: String) -> FlutterError {
    FlutterError(
      code: code,
      message: error.localizedDescription,
      details: String(describing: error)
    )
  }

  @available(iOS 16.2, *)
  private func parse(
    _ payload: [String: Any]
  ) throws -> (
    attributes: MeshMapperActivityAttributes,
    state: MeshMapperActivityAttributes.ContentState
  ) {
    guard let sessionID = boundedString(payload["sessionId"], maxLength: 64),
      let mode = boundedString(payload["mode"], maxLength: 16),
      let phase = boundedString(payload["phase"], maxLength: 32),
      let phaseTitle = boundedString(payload["phaseTitle"], maxLength: 48),
      let updatedAt = date(payload["updatedAt"])
    else {
      throw BridgeError.invalidArguments
    }

    let repeaterPayloads = payload["repeaters"] as? [Any] ?? []
    // Four, because the watch Smart Stack card draws them two columns by two
    // rows. The lock screen and the island still take fewer.
    let repeaters = repeaterPayloads.prefix(4).compactMap {
      rawItem -> MeshMapperActivityAttributes.HeardRepeater? in
      guard let item = rawItem as? [String: Any],
        let id = boundedString(item["id"], maxLength: 16),
        let snr = finiteNumber(item["snr"])
      else {
        return nil
      }
      return MeshMapperActivityAttributes.HeardRepeater(
        id: id,
        name: boundedString(item["name"], maxLength: 36),
        snr: min(max(snr, -200), 200),
        typeColor: resolvedColor(item["typeColor"]),
        snrColor: resolvedColor(item["snrColor"])
      )
    }

    let attributes = MeshMapperActivityAttributes(sessionID: sessionID)
    let state = MeshMapperActivityAttributes.ContentState(
      mode: mode,
      phase: phase,
      phaseTitle: phaseTitle,
      phaseDetail: boundedString(payload["phaseDetail"], maxLength: 80),
      phaseEndsAt: date(payload["phaseEndsAt"]),
      phaseDurationMs: positiveInteger(payload["phaseDurationMs"]),
      pingColor: resolvedColor(payload["pingColor"]),
      isConnected: payload["isConnected"] as? Bool ?? false,
      zoneCode: boundedString(payload["zoneCode"], maxLength: 12),
      txCount: nonnegativeInteger(payload["txCount"]),
      rxCount: nonnegativeInteger(payload["rxCount"]),
      discoveryCount: nonnegativeInteger(payload["discoveryCount"]),
      traceCount: nonnegativeInteger(payload["traceCount"]),
      queueSize: nonnegativeInteger(payload["queueSize"]),
      repeaters: repeaters,
      totalHeardCount: max(nonnegativeInteger(payload["totalHeardCount"]), repeaters.count),
      repeatersAreCurrent: payload["repeatersAreCurrent"] as? Bool ?? false,
      updatedAt: updatedAt
    )
    return (attributes, state)
  }

  @available(iOS 16.2, *)
  @MainActor
  private func sync(
    attributes: MeshMapperActivityAttributes,
    state: MeshMapperActivityAttributes.ContentState
  ) async throws {
    let activities = Activity<MeshMapperActivityAttributes>.activities
    let matching = activities.filter { $0.attributes.sessionID == attributes.sessionID }
    let unrelated = activities.filter { $0.attributes.sessionID != attributes.sessionID }

    for activity in unrelated {
      await end(activity, keepSummaryFor: 0)
    }

    let content = ActivityContent(
      state: state,
      staleDate: staleDate(for: state)
    )

    if let activity = matching.first {
      requestedSessionID = attributes.sessionID
      await activity.update(content)
      for duplicate in matching.dropFirst() {
        await end(duplicate, keepSummaryFor: 0)
      }
      return
    }

    // A missing activity with the same session ID means the user or system
    // dismissed it. Don't recreate it until MeshMapper starts a new session.
    if requestedSessionID == attributes.sessionID {
      return
    }

    requestedSessionID = attributes.sessionID
    do {
      _ = try Activity.request(
        attributes: attributes,
        content: content,
        pushType: nil
      )
    } catch {
      requestedSessionID = nil
      throw error
    }
  }

  @available(iOS 16.2, *)
  private func staleDate(
    for state: MeshMapperActivityAttributes.ContentState
  ) -> Date {
    if let phaseEndsAt = state.phaseEndsAt {
      return phaseEndsAt.addingTimeInterval(45)
    }
    return state.updatedAt.addingTimeInterval(5 * 60)
  }

  @available(iOS 16.2, *)
  @MainActor
  private func endAll(keepSummaryFor seconds: TimeInterval) async {
    for activity in Activity<MeshMapperActivityAttributes>.activities {
      await end(activity, keepSummaryFor: seconds)
    }
  }

  @available(iOS 16.2, *)
  @MainActor
  private func end(
    _ activity: Activity<MeshMapperActivityAttributes>,
    keepSummaryFor seconds: TimeInterval
  ) async {
    var finalState = activity.content.state
    finalState.phase = "stopped"
    finalState.phaseTitle = "Session ended"
    finalState.phaseDetail = summary(for: finalState)
    finalState.phaseEndsAt = nil
    finalState.phaseDurationMs = nil
    finalState.repeatersAreCurrent = false
    finalState.updatedAt = Date()

    let dismissalPolicy: ActivityUIDismissalPolicy =
      seconds > 0
      ? .after(Date().addingTimeInterval(seconds))
      : .immediate
    await activity.end(
      ActivityContent(state: finalState, staleDate: nil),
      dismissalPolicy: dismissalPolicy
    )
  }

  @available(iOS 16.2, *)
  private func summary(
    for state: MeshMapperActivityAttributes.ContentState
  ) -> String {
    var parts = ["TX \(state.txCount)", "RX \(state.rxCount)"]
    if state.discoveryCount > 0 { parts.append("DISC \(state.discoveryCount)") }
    if state.traceCount > 0 { parts.append("TRACE \(state.traceCount)") }
    return parts.joined(separator: " · ")
  }

  private func boundedString(_ value: Any?, maxLength: Int) -> String? {
    guard let value = value as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return String(trimmed.prefix(maxLength))
  }

  private func date(_ value: Any?) -> Date? {
    guard let milliseconds = finiteNumber(value) else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  private func finiteNumber(_ value: Any?) -> Double? {
    let parsed: Double?
    if let number = value as? NSNumber {
      parsed = number.doubleValue
    } else if let value = value as? Double {
      parsed = value
    } else if let value = value as? Int {
      parsed = Double(value)
    } else {
      parsed = nil
    }
    guard let parsed, parsed.isFinite else { return nil }
    return parsed
  }

  private func nonnegativeInteger(_ value: Any?) -> Int {
    if let number = value as? NSNumber { return max(number.intValue, 0) }
    if let value = value as? Int { return max(value, 0) }
    return 0
  }

  private func positiveInteger(_ value: Any?) -> Int? {
    guard let value = finiteNumber(value), value > 0 else { return nil }
    return Int(min(value, Double(24 * 60 * 60 * 1000)))
  }

  /// Guarded like every other member that names the attributes type: the
  /// deployment target predates ActivityKit, so mentioning it unguarded fails
  /// to compile even in a helper that never runs on an older OS.
  @available(iOS 16.2, *)
  private func resolvedColor(
    _ value: Any?
  ) -> MeshMapperActivityAttributes.ResolvedColor? {
    guard let value = value as? [String: Any],
      let r = finiteNumber(value["r"]),
      let g = finiteNumber(value["g"]),
      let b = finiteNumber(value["b"])
    else { return nil }

    return MeshMapperActivityAttributes.ResolvedColor(
      r: min(max(r, 0), 1),
      g: min(max(g, 0), 1),
      b: min(max(b, 0), 1)
    )
  }
}
