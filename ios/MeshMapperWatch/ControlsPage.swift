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
      // button — below the fold, which is the opposite of what it is for.
      VStack(spacing: 10) {
        startStopButton
        manualPingButton

        if let reason = controls?.blockedReason {
          Text(reason)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }

        if let refusal = client.lastRefusal {
          Text(refusal)
            .font(.caption2)
            .foregroundStyle(.orange)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.horizontal, 8)
      .padding(.top, 4)
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

  private var startStopButton: some View {
    let isActive = controls?.isSessionActive ?? false
    let kind: WatchCommand.Kind = isActive ? .stopSession : .startSession
    let isPending = client.pendingCommand == kind
    let isEnabled = controls?.canStartStop == true && !isPending

    return Button {
      client.send(kind)
    } label: {
      HStack(spacing: 6) {
        if isPending {
          ProgressView()
            .controlSize(.small)
        }
        Text(isPending ? (isActive ? "Stopping…" : "Starting…") : (isActive ? "Stop" : "Start"))
          .font(.headline)
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.borderedProminent)
    // Grey when unavailable rather than a desaturated tint: a disabled green
    // renders pale enough to read as a live button worth tapping.
    .tint(isEnabled ? (isActive ? .red : .green) : .gray)
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
      HStack(spacing: 6) {
        if isPending {
          ProgressView()
            .controlSize(.small)
        }
        if let endsAt = cooldownEndsAt {
          // A cooldown is the one unavailability the phone reports without a
          // `blockedReason`, so without this the button would sit dead and
          // unexplained. The deadline is absolute, so the countdown is right
          // even if no further snapshot arrives.
          Text("Ping in")
            .font(.headline)
          Text(timerInterval: Date()...endsAt, countsDown: true)
            .font(.headline.monospacedDigit())
            .frame(width: 38, alignment: .leading)
        } else {
          Text(isPending ? "Sending…" : (pingArmed ? "Send ping?" : "Manual ping"))
            .font(.headline)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.borderedProminent)
    .tint(isEnabled ? (pingArmed ? .orange : .accentColor) : .gray)
    .disabled(!isEnabled)
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
