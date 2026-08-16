import Flutter
import Foundation
import WatchConnectivity

/// Bridges Flutter app state to the watchOS companion and relays commands back.
///
/// Two delivery paths, chosen by urgency:
///
/// - `updateApplicationContext` for the steady state. It coalesces (latest
///   wins) and is delivered even when the watch app is backgrounded or not
///   running, which is what makes the wrist-down case work.
/// - `sendMessage` for phase transitions and ping results, which need to land
///   now. It requires a reachable counterpart, so it always falls back to the
///   application context rather than being the only path.
///
/// WatchConnectivity needs no entitlement and no capability registration —
/// this whole file works without developer-portal access.
final class WatchSessionManager: NSObject {
  private enum BridgeError: LocalizedError {
    case invalidArguments
    case unsupported

    var errorDescription: String? {
      switch self {
      case .invalidArguments: return "The watch payload was invalid."
      case .unsupported: return "WatchConnectivity is unavailable on this device."
      }
    }
  }

  /// Set by AppDelegate so inbound commands can reach Dart.
  ///
  /// Held strongly on purpose. `setMethodCallHandler` makes the binary
  /// messenger retain the handler *block*, not the channel object, so a
  /// channel left in a local goes away when `didFinishLaunchingWithOptions`
  /// returns. The other channels in AppDelegate survive that because they
  /// only ever receive calls; this one has to invoke Dart from native, so it
  /// needs an owner. AppDelegate's handler block captures `self` weakly, so
  /// this does not form a cycle.
  private var channel: FlutterMethodChannel?

  private var session: WCSession? {
    WCSession.isSupported() ? WCSession.default : nil
  }

  /// Last context we successfully handed to WatchConnectivity, so a repeated
  /// identical payload doesn't churn the radio.
  private var lastContextData: Data?

  func attach(channel: FlutterMethodChannel) {
    self.channel = channel
    activateIfNeeded()
  }

  private func activateIfNeeded() {
    guard let session else { return }
    if session.activationState != .activated {
      session.delegate = self
      session.activate()
    }
  }

  // MARK: - Flutter → watch

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "sync":
      guard let args = call.arguments as? [String: Any],
            let payload = args["payload"] as? [String: Any]
      else {
        result(flutterError(BridgeError.invalidArguments, code: "invalid_arguments"))
        return
      }
      let urgent = args["urgent"] as? Bool ?? false
      result(send(payload: payload, urgent: urgent))

    case "clear":
      lastContextData = nil
      result(nil)

    case "status":
      result(statusDictionary())

    default:
      result(FlutterMethodNotImplemented)
    }
  }

  /// Returns false when there is nowhere to deliver to — no paired watch, no
  /// installed app, or no WatchConnectivity at all. Dart treats that as
  /// "don't bother", not as an error.
  private func send(payload: [String: Any], urgent: Bool) -> Bool {
    guard let session, session.activationState == .activated else {
      activateIfNeeded()
      return false
    }
    guard session.isPaired, session.isWatchAppInstalled else { return false }

    guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
      return false
    }

    // Urgent updates try the immediate path first, but always fall through to
    // the application context so a missed message can't strand the watch on
    // stale state.
    if urgent, session.isReachable {
      session.sendMessage(
        [MeshMapperWatchWire.payloadKey: data],
        replyHandler: nil,
        errorHandler: { [weak self] error in
          NSLog("[WATCH] sendMessage failed, context still pending: \(error.localizedDescription)")
          _ = self
        }
      )
    }

    guard data != lastContextData else { return true }

    do {
      try session.updateApplicationContext([MeshMapperWatchWire.payloadKey: data])
      lastContextData = data
      return true
    } catch {
      NSLog("[WATCH] updateApplicationContext failed: \(error.localizedDescription)")
      return false
    }
  }

  private func statusDictionary() -> [String: Any] {
    guard let session else {
      return [
        "supported": false,
        "paired": false,
        "installed": false,
        "reachable": false,
        "activated": false,
      ]
    }
    return [
      "supported": true,
      "paired": session.isPaired,
      "installed": session.isWatchAppInstalled,
      "reachable": session.isReachable,
      "activated": session.activationState == .activated,
    ]
  }

  /// Dart performs the expensive geo build only while a real destination
  /// exists. Push changes as well as answering its startup query: pairing and
  /// app installation can happen after Flutter has been alive for hours, and
  /// a launch-time false must never become a permanent gate.
  private func publishStatus() {
    guard let channel else { return }
    DispatchQueue.main.async {
      channel.invokeMethod("availabilityChanged", arguments: self.statusDictionary())
    }
  }

  private func flutterError(_ error: Error, code: String) -> FlutterError {
    FlutterError(
      code: code,
      message: error.localizedDescription,
      details: String(describing: error)
    )
  }

  // MARK: - watch → Flutter

  /// Relays a command to Dart and returns its admission ack. Dart owns the
  /// synchronous decision and starts accepted work separately; this side never
  /// evaluates whether a transmit is legal or waits for BLE/network completion.
  private func relayCommand(_ payload: [String: Any], reply: @escaping ([String: Any]) -> Void) {
    guard let channel else {
      NSLog("[WATCH] Command dropped: no method channel")
      reply(["accepted": false, "reason": "App not ready"])
      return
    }

    let kind = payload["kind"] as? String ?? "unknown"
    NSLog("[WATCH] Command received: \(kind)")

    // Method channel calls must happen on the main thread; WatchConnectivity
    // delivers on a background queue.
    DispatchQueue.main.async {
      channel.invokeMethod("command", arguments: payload) { response in
        if let dict = response as? [String: Any] {
          NSLog("[WATCH] Command \(kind) acked: accepted=\(dict["accepted"] ?? "?")")
          reply(dict)
        } else {
          NSLog("[WATCH] Command \(kind) got no response from Dart")
          reply(["accepted": false, "reason": "No response"])
        }
      }
    }
  }
}

// MARK: - WCSessionDelegate

extension WatchSessionManager: WCSessionDelegate {
  func session(
    _ session: WCSession,
    activationDidCompleteWith activationState: WCSessionActivationState,
    error: Error?
  ) {
    if let error {
      NSLog("[WATCH] Activation failed: \(error.localizedDescription)")
    }
    publishStatus()
  }

  func sessionDidBecomeInactive(_ session: WCSession) {}

  /// Reactivate after a watch switch, otherwise the session stays dead.
  func sessionDidDeactivate(_ session: WCSession) {
    session.activate()
  }

  func sessionWatchStateDidChange(_ session: WCSession) {
    // Hopped, not written here. WatchConnectivity delivers this on a background
    // thread while `send(payload:urgent:)` reads and writes the same property
    // on the platform thread, which is a plain data race on the dedupe cache —
    // and losing that race means a snapshot the watch needed gets suppressed as
    // "identical" against a value another thread was midway through clearing.
    DispatchQueue.main.async { [weak self] in
      // A newly installed or newly paired watch has no context yet.
      self?.lastContextData = nil
    }
    publishStatus()
  }

  /// The documented signal for reachability changing. Without it, the status
  /// this bridge reports to Dart was only as current as the last activation or
  /// watch-state change, and the diagnostics screen looked live purely because
  /// it polls every five seconds while it is open.
  func sessionReachabilityDidChange(_ session: WCSession) {
    publishStatus()
  }

  func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
    guard let command = userInfo[MeshMapperWatchWire.commandKey] as? [String: Any] else {
      NSLog("[WATCH] Malformed queued command payload: \(Array(userInfo.keys))")
      return
    }
    relayCommand(command) { _ in }
  }

  /// Retained for commands already sent by watch builds that predate the
  /// queued transport; removing it would strand an in-flight wrist action.
  func session(
    _ session: WCSession,
    didReceiveMessage message: [String: Any],
    replyHandler: @escaping ([String: Any]) -> Void
  ) {
    guard let command = message[MeshMapperWatchWire.commandKey] as? [String: Any] else {
      NSLog("[WATCH] Malformed command payload: \(Array(message.keys))")
      replyHandler(["accepted": false, "reason": "Malformed command"])
      return
    }
    relayCommand(command, reply: replyHandler)
  }

  /// The no-reply legacy overload is retained for the same compatibility
  /// window. New watches use `transferUserInfo` exclusively.
  func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
    guard let command = message[MeshMapperWatchWire.commandKey] as? [String: Any] else {
      NSLog("[WATCH] Malformed command payload: \(Array(message.keys))")
      return
    }
    relayCommand(command) { _ in }
  }
}
