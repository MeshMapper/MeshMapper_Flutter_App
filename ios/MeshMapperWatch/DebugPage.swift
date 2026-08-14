import SwiftUI

#if DEBUG
/// Raw state dump and command buttons.
///
/// Kept from Phase 2 as a development surface while the real UI is built out.
/// Phase 5 replaces the buttons with the proper controls page; this page goes
/// away once the node list and controls carry their own verification.
struct DebugPage: View {
  @Environment(WatchSessionClient.self) private var client
  @Environment(WatchSettings.self) private var settings

  @State private var pingArmed = false
  @State private var disarmPingTask: Task<Void, Never>?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 8) {
        header

        if client.versionMismatch {
          Text("Update MeshMapper on iPhone — wire version mismatch")
            .font(.caption2)
            .foregroundStyle(.orange)
        }

        if let snapshot = client.snapshot {
          session(snapshot)
          counters(snapshot)
          geo(snapshot)
          controls(snapshot)
        } else {
          Text("No snapshot yet")
            .font(.caption2)
            .foregroundStyle(.secondary)
        }

        commandButtons

        if let refusal = client.lastRefusal {
          Text(refusal)
            .font(.caption2)
            .foregroundStyle(.orange)
        }
      }
      .padding(.horizontal, 4)
      .opacity(client.isStale ? 0.45 : 1.0)
    }
    .onDisappear { disarmPing() }
  }

  private var header: some View {
    HStack {
      Circle()
        .fill(client.isReachable ? .green : .gray)
        .frame(width: 6, height: 6)
      Text(client.isReachable ? "Reachable" : "Unreachable")
        .font(.caption2)
      Spacer()
      if let receivedAt = client.receivedAt {
        Text(receivedAt, style: .relative)
          .font(.system(size: 9))
          .foregroundStyle(.secondary)
      }
    }
  }

  private func session(_ s: WatchSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(s.phaseTitle).font(.headline).lineLimit(2)
      if let detail = s.phaseDetail {
        Text(detail).font(.caption2).foregroundStyle(.secondary)
      }
      HStack(spacing: 4) {
        if let color = s.pingColor {
          Circle().fill(Color(color)).frame(width: 8, height: 8)
        }
        Text(s.mode).font(.caption2)
        if let endsAt = s.phaseEndsAt, endsAt > Date() {
          Text(timerInterval: Date()...endsAt, countsDown: true)
            .font(.caption.monospacedDigit())
        }
      }
    }
  }

  private func counters(_ s: WatchSnapshot) -> some View {
    Text("TX \(s.txCount) · RX \(s.rxCount) · DISC \(s.discoveryCount) · Q \(s.queueSize)")
      .font(.system(size: 10).monospacedDigit())
      .foregroundStyle(.secondary)
  }

  private func geo(_ s: WatchSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let you = s.geo.you {
        Text(String(format: "%.5f, %.5f", you.lat, you.lon))
          .font(.system(size: 10).monospacedDigit())
      } else {
        Text("No GPS fix").font(.system(size: 10)).foregroundStyle(.secondary)
      }
      Text("pings \(s.geo.pings.count) · rptrs \(s.geo.repeaters.count) · heard \(s.geo.heard.count)")
        .font(.system(size: 10).monospacedDigit())
        .foregroundStyle(.secondary)

      ForEach(s.geo.heard) { node in
        HStack(spacing: 4) {
          Circle().fill(Color(node.typeColor)).frame(width: 5, height: 5)
          Text(node.id)
            .font(.system(size: 10, design: .monospaced))
          if let name = node.name {
            Text(name)
              .font(.system(size: 10))
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          Spacer()
          if let snr = node.snr {
            Text(String(format: "%.1f", snr))
              .font(.system(size: 10).monospacedDigit())
          }
        }
      }
    }
  }

  private func controls(_ s: WatchSnapshot) -> some View {
    VStack(alignment: .leading, spacing: 1) {
      Text("start/stop \(s.controls.canStartStop ? "✓" : "✗") · ping \(s.controls.canManualPing ? "✓" : "✗")")
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
      if let reason = s.controls.blockedReason {
        Text(reason).font(.system(size: 10)).foregroundStyle(.secondary)
      }
    }
  }

  private var commandButtons: some View {
    VStack(spacing: 4) {
      Button(sessionActive ? "Stop" : "Start \(effectiveStartMode.label)") {
        if sessionActive {
          client.send(.stopSession)
        } else {
          client.send(.startSession, mode: effectiveStartMode.rawValue)
        }
      }
      .disabled(!(client.snapshot?.controls.canStartStop ?? false))

      Button(pingArmed ? "Send ping?" : "Manual ping") {
        if pingArmed {
          disarmPing()
          client.send(.manualPing)
        } else {
          armPing()
        }
      }
        .disabled(!(client.snapshot?.controls.canManualPing ?? false))

      Button("Refresh") { client.send(.requestSnapshot) }
    }
    .font(.caption2)
    .buttonStyle(.bordered)
  }

  private var sessionActive: Bool {
    client.snapshot?.controls.isSessionActive ?? false
  }

  private var effectiveStartMode: WatchSettings.DefaultStartMode {
    settings.effectiveStartMode(
      availableStartModes: client.snapshot?.availableStartModes
    )
  }

  /// DEBUG still reaches physical development watches, so its raw-state page
  /// keeps the same deliberate second tap as every shipping ping surface.
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
#endif
