import ActivityKit
import SwiftUI
import WidgetKit

struct MeshMapperLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: MeshMapperActivityAttributes.self) { context in
      Group {
        if #available(iOSApplicationExtension 18.0, *) {
          MeshMapperResponsiveActivityView(context: context)
        } else {
          MeshMapperLockScreenView(context: context)
        }
      }
      .activityBackgroundTint(MeshMapperPalette.background)
      .activitySystemActionForegroundColor(.white)
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          MeshMapperModeBadge(mode: context.state.mode)
        }
        DynamicIslandExpandedRegion(.trailing) {
          MeshMapperBestSignal(state: context.state)
        }
        DynamicIslandExpandedRegion(.center) {
          MeshMapperPhaseLabel(state: context.state)
        }
        DynamicIslandExpandedRegion(.bottom) {
          MeshMapperIslandBottom(state: context.state)
        }
      } compactLeading: {
        Image(
          systemName: context.isStale
            ? "exclamationmark.triangle.fill" : context.state.phaseSymbol
        )
        .foregroundStyle(context.isStale ? Color.orange : context.state.phaseColor)
        .accessibilityLabel(context.isStale ? "Update delayed" : context.state.phaseTitle)
      } compactTrailing: {
        MeshMapperCompactTrailing(state: context.state)
      } minimal: {
        Image(
          systemName: context.isStale
            ? "exclamationmark.triangle.fill" : context.state.phaseSymbol
        )
        .foregroundStyle(context.isStale ? Color.orange : context.state.phaseColor)
        .accessibilityLabel(context.isStale ? "Update delayed" : context.state.phaseTitle)
      }
      .keylineTint(context.state.phaseColor)
    }
    .meshMapperSupplementalActivityFamilies()
  }
}

extension ActivityConfiguration {
  fileprivate func meshMapperSupplementalActivityFamilies() -> some WidgetConfiguration {
    if #available(iOSApplicationExtension 18.0, *) {
      return supplementalActivityFamilies([.small])
    } else {
      return self
    }
  }
}

@available(iOSApplicationExtension 18.0, *)
private struct MeshMapperResponsiveActivityView: View {
  @Environment(\.activityFamily) private var activityFamily
  let context: ActivityViewContext<MeshMapperActivityAttributes>

  var body: some View {
    if activityFamily == .small {
      MeshMapperSmallActivityView(context: context)
    } else {
      MeshMapperLockScreenView(context: context)
    }
  }
}

private struct MeshMapperLockScreenView: View {
  let context: ActivityViewContext<MeshMapperActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      HStack(spacing: 8) {
        MeshMapperModeBadge(mode: context.state.mode)
        Spacer(minLength: 8)
        MeshMapperStatusLabel(context: context)
      }

      HStack(alignment: .center, spacing: 9) {
        Image(systemName: context.state.phaseSymbol)
          .font(.title3.weight(.semibold))
          .foregroundStyle(context.state.phaseColor)
          .frame(width: 24)
          .accessibilityHidden(true)

        VStack(alignment: .leading, spacing: 1) {
          Text(context.state.phaseTitle)
            .font(.headline.weight(.semibold))
            .lineLimit(1)
          if let detail = context.state.phaseDetail, !detail.isEmpty {
            Text(detail)
              .font(.caption2)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
        }

        Spacer(minLength: 6)
        MeshMapperCountdown(
          state: context.state,
          font: .headline.monospacedDigit().weight(.semibold)
        )
      }

      HStack(alignment: .bottom, spacing: 12) {
        MeshMapperRepeaterSummary(state: context.state)
          .frame(maxWidth: .infinity, alignment: .leading)

        VStack(alignment: .trailing, spacing: 4) {
          HStack(spacing: 9) {
            MeshMapperMetric(
              label: context.state.primaryMetricLabel,
              value: context.state.primaryMetricValue
            )
            MeshMapperMetric(label: "RX", value: context.state.rxCount)
          }
          if context.state.queueSize > 0 {
            Label("Queue \(context.state.queueSize)", systemImage: "arrow.triangle.2.circlepath")
              .font(.caption2.monospacedDigit().weight(.medium))
              .foregroundStyle(.secondary)
          }
        }
      }
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .foregroundStyle(.white)
  }
}

@available(iOSApplicationExtension 18.0, *)
private struct MeshMapperSmallActivityView: View {
  let context: ActivityViewContext<MeshMapperActivityAttributes>

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 7) {
        Image(systemName: context.state.phaseSymbol)
          .foregroundStyle(context.state.phaseColor)
          .accessibilityHidden(true)
        Text(context.state.mode.uppercased())
          .font(.caption2.weight(.bold))
          .tracking(0.6)
        Spacer(minLength: 4)
        if context.isStale {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .accessibilityLabel("Update delayed")
        } else if let zone = context.state.zoneCode {
          Text(zone)
            .font(.system(.caption2, design: .monospaced).weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }

      HStack(alignment: .firstTextBaseline, spacing: 6) {
        Text(context.state.phaseTitle)
          .font(.headline.weight(.semibold))
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Spacer(minLength: 4)
        MeshMapperCountdown(
          state: context.state,
          font: .headline.monospacedDigit().weight(.semibold)
        )
      }

      MeshMapperBestRepeaterRow(state: context.state)

      HStack(spacing: 10) {
        Text("\(context.state.primaryMetricLabel) \(context.state.primaryMetricValue)")
        Text("RX \(context.state.rxCount)")
        Spacer(minLength: 0)
        if context.state.queueSize > 0 {
          Label("\(context.state.queueSize)", systemImage: "arrow.triangle.2.circlepath")
        }
      }
      .font(.caption2.monospacedDigit().weight(.medium))
      .foregroundStyle(.secondary)
    }
    .padding(12)
    .foregroundStyle(.white)
  }
}

private struct MeshMapperStatusLabel: View {
  let context: ActivityViewContext<MeshMapperActivityAttributes>

  var body: some View {
    Label(
      context.isStale
        ? "Update delayed" : context.state.zoneCode ?? context.state.connectionLabel,
      systemImage: context.isStale
        ? "exclamationmark.triangle.fill"
        : context.state.isConnected
          ? "antenna.radiowaves.left.and.right"
          : "wifi.slash"
    )
    .font(.caption2.weight(.semibold))
    .lineLimit(1)
    .foregroundStyle(
      context.isStale || !context.state.isConnected
        ? Color.orange : MeshMapperPalette.secondary
    )
  }
}

private struct MeshMapperRepeaterSummary: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Text(state.repeatersAreCurrent ? "HEARD NOW" : "LAST HEARD")
          .font(.caption2.weight(.bold))
          .tracking(0.6)
          .foregroundStyle(.secondary)
        if state.totalHeardCount > 0 {
          Text("\(state.totalHeardCount)")
            .font(.caption2.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }

      if state.repeaters.isEmpty {
        Text(state.repeaterEmptyLabel)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      } else {
        ForEach(state.repeaters.prefix(2)) { repeater in
          HStack(spacing: 6) {
            Circle()
              .fill(MeshMapperPalette.secondary)
              .frame(width: 5, height: 5)
              .accessibilityHidden(true)
            Text(repeater.displayName)
              .font(.caption.weight(.medium))
              .lineLimit(1)
            Text(repeater.snr.formattedSnr)
              .font(.caption.monospacedDigit().weight(.semibold))
              .foregroundStyle(.secondary)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel("\(repeater.displayName), SNR \(repeater.snr.formattedSnr)")
        }
      }
    }
  }
}

private struct MeshMapperBestRepeaterRow: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    if let best = state.repeaters.first {
      HStack(spacing: 6) {
        Image(systemName: "antenna.radiowaves.left.and.right")
          .font(.caption2)
          .foregroundStyle(MeshMapperPalette.secondary)
          .accessibilityHidden(true)
        Text(best.displayName)
          .font(.caption.weight(.medium))
          .lineLimit(1)
        Spacer(minLength: 4)
        Text(best.snr.formattedSnr)
          .font(.caption.monospacedDigit().weight(.semibold))
        if state.totalHeardCount > 1 {
          Text("+\(state.totalHeardCount - 1)")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(
        "Best repeater \(best.displayName), SNR \(best.snr.formattedSnr), "
          + "\(state.totalHeardCount) heard"
      )
    } else {
      Text(state.repeaterEmptyLabel)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
  }
}

private struct MeshMapperIslandBottom: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    VStack(spacing: 6) {
      MeshMapperBestRepeaterRow(state: state)
      HStack(spacing: 12) {
        Text("\(state.primaryMetricLabel) \(state.primaryMetricValue)")
        Text("RX \(state.rxCount)")
        if let zone = state.zoneCode {
          Spacer()
          Text(zone)
        }
      }
      .font(.caption.monospacedDigit().weight(.medium))
      .foregroundStyle(.secondary)
    }
  }
}

private struct MeshMapperModeBadge: View {
  let mode: String

  var body: some View {
    Label(mode.uppercased(), systemImage: "antenna.radiowaves.left.and.right")
      .font(.caption2.weight(.bold))
      .tracking(0.6)
      .foregroundStyle(.white)
      .padding(.horizontal, 8)
      .padding(.vertical, 4)
      .background(MeshMapperPalette.primary, in: Capsule())
  }
}

private struct MeshMapperPhaseLabel: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    VStack(spacing: 2) {
      Text(state.phaseTitle)
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
      MeshMapperCountdown(
        state: state,
        font: .caption.monospacedDigit().weight(.semibold)
      )
      .foregroundStyle(.secondary)
    }
  }
}

private struct MeshMapperBestSignal: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    if let best = state.repeaters.first {
      VStack(alignment: .trailing, spacing: 2) {
        Text(best.snr.formattedSnr)
          .font(.subheadline.monospacedDigit().weight(.semibold))
        Text("best SNR")
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel("Best SNR \(best.snr.formattedSnr)")
    } else {
      Image(systemName: "waveform.slash")
        .foregroundStyle(.secondary)
        .accessibilityLabel("No repeaters heard")
    }
  }
}

private struct MeshMapperCompactTrailing: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    if state.hasActiveCountdown {
      MeshMapperCountdown(
        state: state,
        font: .caption2.monospacedDigit().weight(.bold)
      )
      .frame(minWidth: 28)
    } else if let best = state.repeaters.first {
      Text(best.snr.formattedSnr)
        .font(.caption2.monospacedDigit().weight(.bold))
        .accessibilityLabel("Best SNR \(best.snr.formattedSnr)")
    } else {
      Text("\(state.rxCount)")
        .font(.caption2.monospacedDigit().weight(.bold))
        .accessibilityLabel("\(state.rxCount) received")
    }
  }
}

private struct MeshMapperCountdown: View {
  let state: MeshMapperActivityAttributes.ContentState
  let font: Font

  var body: some View {
    if let end = state.phaseEndsAt, end > Date() {
      Text(timerInterval: Date()...end, countsDown: true, showsHours: false)
        .font(font)
        .lineLimit(1)
        .accessibilityLabel("Time remaining")
    }
  }
}

private struct MeshMapperMetric: View {
  let label: String
  let value: Int

  var body: some View {
    Text("\(label) \(value)")
      .font(.caption.monospacedDigit().weight(.semibold))
      .foregroundStyle(.secondary)
      .accessibilityLabel("\(label) \(value)")
  }
}

private enum MeshMapperPalette {
  static let background = Color(red: 0.055, green: 0.075, blue: 0.105)
  static let primary = Color(red: 0.12, green: 0.43, blue: 0.92)
  static let secondary = Color(red: 0.30, green: 0.82, blue: 0.78)
}

extension MeshMapperActivityAttributes.ContentState {
  fileprivate var hasActiveCountdown: Bool {
    guard let phaseEndsAt else { return false }
    return phaseEndsAt > Date()
  }

  fileprivate var connectionLabel: String {
    isConnected ? "Connected" : "Disconnected"
  }

  fileprivate var primaryMetricLabel: String {
    switch mode.lowercased() {
    case "passive": return "DISC"
    case "trace": return "TRACE"
    default: return "TX"
    }
  }

  fileprivate var primaryMetricValue: Int {
    switch mode.lowercased() {
    case "passive": return discoveryCount
    case "trace": return traceCount
    default: return txCount
    }
  }

  fileprivate var repeaterEmptyLabel: String {
    switch phase {
    case "listening", "listening_discovery", "listening_trace":
      return "No repeaters heard yet"
    default:
      return "No repeaters heard in the last cycle"
    }
  }

  fileprivate var phaseSymbol: String {
    switch phase {
    case "sending": return "arrow.up.circle.fill"
    case "discovering": return "dot.radiowaves.left.and.right"
    case "tracing": return "scope"
    case "listening", "listening_discovery", "listening_trace": return "waveform"
    case "waiting", "waiting_discovery", "waiting_trace", "cooldown": return "timer"
    case "skipped": return "forward.end.fill"
    case "stopping", "stopped": return "stop.circle.fill"
    case "waiting_for_gps": return "location.slash.fill"
    case "paused_outside_zone": return "map.fill"
    case "disconnected": return "wifi.slash"
    case "tx_blocked": return "nosign"
    case "starting": return "hourglass"
    default: return "antenna.radiowaves.left.and.right"
    }
  }

  fileprivate var phaseColor: Color {
    switch phase {
    case "sending", "discovering", "tracing": return MeshMapperPalette.primary
    case "listening", "listening_discovery", "listening_trace": return MeshMapperPalette.secondary
    case "waiting", "waiting_discovery", "waiting_trace", "cooldown": return .cyan
    case "skipped", "waiting_for_gps", "paused_outside_zone": return .orange
    case "disconnected", "tx_blocked": return .red
    case "stopped": return .gray
    default: return .white
    }
  }
}

extension Double {
  fileprivate var formattedSnr: String {
    let sign = self >= 0 ? "+" : ""
    return "\(sign)\(formatted(.number.precision(.fractionLength(1)))) dB"
  }
}
