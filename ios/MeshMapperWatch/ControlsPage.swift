import SwiftUI

/// Session controls sized for deliberate use while moving.
///
/// Availability is only the phone's last-reported state. The watch does not
/// duplicate transport, GPS, cooldown, or session guards; every tap still goes
/// to the phone, which revalidates it and returns the reason when refused.
struct ControlsPage: View {
  @Environment(WatchSessionClient.self) private var client

  @State private var pingArmed = false
  @State private var disarmPingTask: Task<Void, Never>?

  private static let minimumTapHeight: CGFloat = 44
  private static let compactLabelHeight: CGFloat = 24

  private var controls: WatchControls? { client.snapshot?.controls }

  /// Manual-ping cooldown deadline, if one is still ahead of us.
  private var cooldownEndsAt: Date? {
    guard let ms = controls?.manualCooldownEndsAtMs else { return nil }
    let endsAt = Date(timeIntervalSince1970: ms / 1000)
    return endsAt > Date() ? endsAt : nil
  }

  var body: some View {
    ScrollView {
      // No page title. The buttons name themselves, and on a 40 mm screen a
      // header pushed `blockedReason` — the one thing that explains a dead
      // button — below the fold, which is the opposite of what it is for. The
      // compact in-card context adds meaning without spending a navigation row.
      VStack(spacing: 5) {
        sessionHeader
        startStopControl
        manualPingControl

        // A fresh cue retained across a watch-process restart has no local tap
        // to name. Keep that rare but valid feedback visible without guessing
        // which control owns it.
        if client.lastRefusalCommand == nil,
           let refusal = client.lastRefusal
        {
          refusalMessage(refusal)
        }
      }
      .padding(.horizontal, 6)
      .padding(.vertical, 5)
      .background(
        .ultraThinMaterial,
        in: .rect(cornerRadius: WatchPalette.cornerRadius, style: .continuous)
      )
      .overlay(
        RoundedRectangle(
          cornerRadius: WatchPalette.cornerRadius,
          style: .continuous
        )
          .stroke(.white.opacity(0.12), lineWidth: 0.5)
      )
      .padding(.horizontal, 6)
      .padding(.top, 2)
      // The last line must not finish against the bottom edge: the display
      // curves there, and the simulator's flat rectangle has hidden exactly
      // this twice before.
      .padding(.bottom, 14)
    }
    // These are fixed pieces of control chrome rather than reading content;
    // bounding type preserves the large tap targets on the smallest watch.
    .dynamicTypeSize(.small ... .large)
    .opacity(client.isStale ? 0.5 : 1.0)
    .onChange(of: controls?.canManualPing) { _, canManualPing in
      if canManualPing != true { disarmPing() }
    }
    .onDisappear { disarmPing() }
  }

  private var sessionHeader: some View {
    HStack(alignment: .firstTextBaseline, spacing: 0) {
      // The mode doubles as the compact section label. A separate "SESSION"
      // row would spend the exact vertical space that keeps a two-line blocked
      // reason visible on the 40 mm display.
      Text(controls?.isSessionActive == true
        ? (client.snapshot?.mode.uppercased() ?? "SESSION")
        : "IDLE")
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(.white.opacity(0.55))
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)

      Spacer(minLength: 4)

      Text(client.snapshot?.phaseTitle ?? "Waiting for iPhone")
        // Phase titles are prose, not an identity or numeric value. The
        // proportional face plus bounded scaling keeps even "Device
        // disconnected" and "Listening for trace…" intact on 40 mm without
        // buying that width by pushing the blocked reason below the fold.
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .allowsTightening(true)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var startStopControl: some View {
    VStack(alignment: .leading, spacing: 2) {
      startStopButton
      if controls?.canStartStop != true,
         let reason = controls?.blockedReason
      {
        controlReason(reason)
      }
      if let refusal = startStopRefusal {
        refusalMessage(refusal)
      }
    }
  }

  private var manualPingControl: some View {
    VStack(alignment: .leading, spacing: 2) {
      manualPingButton
      // When Start/Stop is also unavailable, its action owns the shared reason
      // above. Otherwise keep the explanation immediately under Manual ping.
      if controls?.canStartStop == true,
         controls?.canManualPing != true,
         let reason = controls?.blockedReason
      {
        controlReason(reason)
      }
      if client.lastRefusalCommand == .manualPing,
         let refusal = client.lastRefusal
      {
        refusalMessage(refusal)
      }
    }
  }

  private var startStopRefusal: String? {
    switch client.lastRefusalCommand {
    case .startSession, .stopSession:
      return client.lastRefusal
    default:
      return nil
    }
  }

  private func controlReason(_ reason: String) -> some View {
    Text(reason)
      .font(.system(size: 10, weight: .medium))
      .foregroundStyle(.white.opacity(0.45))
      .multilineTextAlignment(.leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.horizontal, 4)
  }

  private func refusalMessage(_ refusal: String) -> some View {
    HStack(alignment: .firstTextBaseline, spacing: 4) {
      Image(systemName: "exclamationmark.circle.fill")
      Text(refusal)
    }
    .font(.system(size: 10, weight: .medium))
    .foregroundStyle(WatchPalette.armed)
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 4)
  }

  private var startStopButton: some View {
    let isActive = controls?.isSessionActive ?? false
    let kind: WatchCommand.Kind = isActive ? .stopSession : .startSession
    let isPending = client.pendingCommand == kind
    let isEnabled = controls?.canStartStop == true && !isPending
    let startTitle = "Start \(client.snapshot?.mode ?? "Session")"
    let buttonTitle = isPending
      ? (isActive ? "Stopping…" : "Starting…")
      : (isActive ? "Stop" : startTitle)

    return Button {
      client.send(kind)
    } label: {
      Text(buttonTitle)
        .font(.system(size: 13, weight: .semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .frame(maxWidth: .infinity, minHeight: Self.compactLabelHeight)
        // A ProgressView accepts the horizontal slack offered by a stack. As
        // an overlay it can appear without participating in the label's
        // centring, so feedback never makes the action jump under a thumb.
        .overlay(alignment: .leading) {
          if isPending {
            ProgressView()
              .controlSize(.small)
              .frame(width: 16, height: 16)
              .padding(.leading, 6)
          }
        }
    }
    .buttonStyle(.borderedProminent)
    // The prominent watch style supplies substantial chrome outside its
    // label. Giving the label the full ergonomic floor made the finished
    // target 69.5 pt tall; applying that floor to the styled Button preserves
    // the moving-vehicle tap target without paying for it twice.
    .frame(minHeight: Self.minimumTapHeight)
    .buttonBorderShape(.roundedRectangle(radius: WatchPalette.cornerRadius))
    .tint(isEnabled
      ? (isActive ? WatchPalette.stop : WatchPalette.start)
      : WatchPalette.disabled)
    .disabled(!isEnabled)
  }

  private var manualPingButton: some View {
    let isPending = client.pendingCommand == .manualPing
    let isEnabled = controls?.canManualPing == true && !isPending

    return Button {
      if pingArmed {
        disarmPing()
        client.send(.manualPing)
      } else {
        armPing()
      }
    } label: {
      pingLabel(isPending: isPending)
        .frame(maxWidth: .infinity, minHeight: Self.compactLabelHeight)
      // Keep this identical to Start/Stop: pending feedback belongs at the
      // edge of the target, not in the row that determines its label's centre.
      .overlay(alignment: .leading) {
        if isPending {
          ProgressView()
            .controlSize(.small)
            .frame(width: 16, height: 16)
            .padding(.leading, 6)
        }
      }
    }
    .buttonStyle(.borderedProminent)
    .frame(minHeight: Self.minimumTapHeight)
    .buttonBorderShape(.roundedRectangle(radius: WatchPalette.cornerRadius))
    .tint(isEnabled
      ? (pingArmed ? WatchPalette.armed : WatchPalette.ping)
      : WatchPalette.disabled)
    .disabled(!isEnabled)
  }

  /// The ping button's label, as exactly one view.
  ///
  /// A `Group` will not do here: with two children it applies each modifier to
  /// both, so `maxWidth: .infinity` went to the words *and* the timer and threw
  /// them to opposite ends of the button. The pair has to be its own stack to
  /// read as one centred label.
  ///
  /// A cooldown is the one unavailability the phone reports without a
  /// `blockedReason`, so without this the button would sit dead and unexplained.
  /// The deadline is absolute, so the countdown stays right even if no further
  /// snapshot arrives.
  @ViewBuilder
  private func pingLabel(isPending: Bool) -> some View {
    if let endsAt = cooldownEndsAt {
      HStack(spacing: 5) {
        Text("Ping in")
        Text(timerInterval: Date()...endsAt, countsDown: true)
          .monospacedDigit()
          .frame(width: 38, alignment: .leading)
      }
      .font(.system(size: 13, weight: .semibold))
    } else {
      Text(isPending ? "Sending…" : (pingArmed ? "Send ping?" : "Manual ping"))
        .font(.system(size: 13, weight: .semibold))
    }
  }

  /// The first tap buys a short confirmation window; expiry returns the button
  /// to a harmless state without involving the phone or transmitting anything.
  private func armPing() {
    disarmPingTask?.cancel()
    pingArmed = true
    disarmPingTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled else { return }
      pingArmed = false
      disarmPingTask = nil
    }
  }

  private func disarmPing() {
    disarmPingTask?.cancel()
    disarmPingTask = nil
    pingArmed = false
  }
}
