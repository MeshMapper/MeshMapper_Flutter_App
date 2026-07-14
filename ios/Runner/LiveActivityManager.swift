import ActivityKit
import Flutter
import Foundation

/// Native ActivityKit endpoint for the Flutter method channel.
///
/// Flutter sends complete snapshots. The manager keeps at most one activity,
/// updates it serially, and doesn't recreate a Live Activity the user dismissed
/// during the same wardriving session.
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
      guard #available(iOS 16.2, *) else {
        result(false)
        return
      }
      guard ActivityAuthorizationInfo().areActivitiesEnabled else {
        result(false)
        return
      }

      Task { @MainActor in
        do {
          let parsed = try parse(payload)
          try await sync(attributes: parsed.attributes, state: parsed.state)
          result(true)
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
    let repeaters = repeaterPayloads.prefix(3).compactMap {
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
        snr: min(max(snr, -200), 200)
      )
    }

    let attributes = MeshMapperActivityAttributes(sessionID: sessionID)
    let state = MeshMapperActivityAttributes.ContentState(
      mode: mode,
      phase: phase,
      phaseTitle: phaseTitle,
      phaseDetail: boundedString(payload["phaseDetail"], maxLength: 80),
      phaseEndsAt: date(payload["phaseEndsAt"]),
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
}
