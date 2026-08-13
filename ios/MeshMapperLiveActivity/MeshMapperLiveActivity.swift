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
          MeshMapperIslandOutcome(state: context.state, isStale: context.isStale)
        }
        DynamicIslandExpandedRegion(.center) {
          Text(context.state.zoneCode ?? context.state.connectionLabel)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(context.isStale ? Color.orange : .secondary)
            .lineLimit(1)
        }
        DynamicIslandExpandedRegion(.bottom) {
          MeshMapperIslandBottom(state: context.state)
        }
      } compactLeading: {
        Image(
          systemName: context.isStale
            ? "exclamationmark.triangle.fill" : context.state.phaseSymbol
        )
        .foregroundStyle(context.isStale ? Color.orange : context.state.displayColor)
        .accessibilityLabel(context.isStale ? "Update delayed" : context.state.phaseTitle)
      } compactTrailing: {
        MeshMapperCompactTrailing(state: context.state)
      } minimal: {
        if context.isStale {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .accessibilityLabel("Update delayed")
        } else {
          // With room for one mark, the latest result matters more than mode
          // or phase. This remains useful when an unanswered ping has no rows.
          MeshMapperOutcomeDot(state: context.state, diameter: 9)
        }
      }
      .keylineTint(context.state.displayColor)
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
      MeshMapperSmallActivityContent(
        state: context.state,
        isStale: context.isStale
      )
    } else {
      MeshMapperLockScreenContent(
        state: context.state,
        isStale: context.isStale
      )
    }
  }
}

private struct MeshMapperLockScreenView: View {
  let context: ActivityViewContext<MeshMapperActivityAttributes>

  var body: some View {
    MeshMapperLockScreenContent(
      state: context.state,
      isStale: context.isStale
    )
  }
}

private struct MeshMapperLockScreenContent: View {
  let state: MeshMapperActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 9) {
      MeshMapperPhaseBar(
        state: state,
        height: 20,
        titleFont: .subheadline.weight(.semibold),
        countdownFont: .subheadline.monospacedDigit().weight(.semibold),
        countdownWidth: 54
      )

      HStack(spacing: 8) {
        MeshMapperModeBadge(mode: state.mode)
        // Counts describe the session, so they belong beside its mode. Keeping
        // them out of the repeater stack prevents the last row from reading as
        // though TX, RX, and queue values belong to that individual node.
        MeshMapperMetrics(state: state, compact: false)
        Spacer(minLength: 6)
        MeshMapperStatusLabel(state: state, isStale: isStale)
      }

      MeshMapperRepeaterSummary(
        state: state,
        limit: 3,
        showsNames: true,
        rowFont: .caption
      )
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 12)
    .foregroundStyle(.white)
  }
}

@available(iOSApplicationExtension 18.0, *)
private struct MeshMapperSmallActivityContent: View {
  let state: MeshMapperActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 7) {
      MeshMapperPhaseBar(
        state: state,
        height: 18,
        titleFont: .caption.weight(.semibold),
        countdownFont: .caption2.monospacedDigit().weight(.bold),
        countdownWidth: 40
      )

      HStack(spacing: 6) {
        Text(state.mode.uppercased())
          .font(.caption2.weight(.bold))
          .tracking(0.6)
        Spacer(minLength: 3)
        if isStale {
          Image(systemName: "exclamationmark.triangle.fill")
            .font(.caption2)
            .foregroundStyle(.orange)
            .accessibilityLabel("Update delayed")
        } else {
          MeshMapperOutcomeDot(state: state, diameter: 7)
          if let zone = state.zoneCode {
            Text(zone)
              .font(.system(.caption2, design: .monospaced).weight(.semibold))
              .foregroundStyle(.secondary)
          }
        }
      }

      MeshMapperRepeaterSummary(
        state: state,
        limit: 2,
        showsNames: false,
        rowFont: .caption2
      )

      MeshMapperMetrics(state: state, compact: true)
    }
    .padding(12)
    .foregroundStyle(.white)
  }
}

/// The phase as a locally depleting bar, matching the watch map panel.
///
/// Absolute deadline plus duration lets SwiftUI animate between sparse phone
/// updates. The title and countdown ride over the fill so neither consumes
/// track width, and their shadow keeps them legible on both halves.
private struct MeshMapperPhaseBar: View {
  let state: MeshMapperActivityAttributes.ContentState
  let height: CGFloat
  let titleFont: Font
  let countdownFont: Font
  let countdownWidth: CGFloat

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      GeometryReader { geometry in
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.16))
          Capsule()
            .fill(state.displayColor)
            .frame(
              width: geometry.size.width
                * (state.phaseRemainingFraction(at: context.date) ?? 0)
            )
        }
        .overlay {
          HStack {
            Text(state.phaseTitle)
              .font(titleFont)
              .foregroundStyle(
                .white.opacity(state.deadlineLapsed(at: context.date) ? 0.45 : 1)
              )
              .lineLimit(1)
              .truncationMode(.tail)
            Spacer(minLength: 4)
            MeshMapperCountdown(
              state: state,
              at: context.date,
              font: countdownFont
            )
            .frame(width: countdownWidth, alignment: .trailing)
          }
          .padding(.horizontal, 7)
          .shadow(color: .black.opacity(0.7), radius: 1.5)
        }
      }
    }
    .frame(height: height)
  }
}

private struct MeshMapperStatusLabel: View {
  let state: MeshMapperActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    Label(
      isStale ? "Update delayed" : state.zoneCode ?? state.connectionLabel,
      systemImage: isStale
        ? "exclamationmark.triangle.fill"
        : state.isConnected
          ? "antenna.radiowaves.left.and.right"
          : "wifi.slash"
    )
    .font(.caption2.weight(.semibold))
    .lineLimit(1)
    .foregroundStyle(isStale || !state.isConnected ? Color.orange : .secondary)
  }
}

private struct MeshMapperRepeaterSummary: View {
  let state: MeshMapperActivityAttributes.ContentState
  let limit: Int
  let showsNames: Bool
  let rowFont: Font

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 5) {
        Text(state.repeatersAreCurrent ? "HEARD NOW" : "LAST HEARD")
          .font(.caption2.weight(.bold))
          .tracking(0.6)
        if state.totalHeardCount > 0 {
          Text("\(state.totalHeardCount)")
            .font(.caption2.monospacedDigit().weight(.semibold))
        }
      }
      .foregroundStyle(.secondary)

      if state.repeaters.isEmpty {
        HStack(spacing: 6) {
          // A failed ping produces no rows, so its colour needs its own mark;
          // absence alone cannot distinguish failure from no attempt yet.
          MeshMapperOutcomeDot(state: state, diameter: 6)
          Text(state.repeaterEmptyLabel)
            .font(rowFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
      } else {
        ForEach(state.repeaters.prefix(limit)) { repeater in
          MeshMapperRepeaterRow(
            repeater: repeater,
            fallbackColor: state.displayColor,
            showsName: showsNames,
            font: rowFont
          )
        }
      }
    }
  }
}

private struct MeshMapperRepeaterRow: View {
  let repeater: MeshMapperActivityAttributes.HeardRepeater
  let fallbackColor: Color
  let showsName: Bool
  let font: Font

  var body: some View {
    HStack(spacing: 6) {
      Circle()
        .fill(repeater.typeColor.map(Color.init) ?? fallbackColor)
        .frame(width: 6, height: 6)
        .accessibilityHidden(true)
      // The path hash remains primary even when a friendly name resolves: it
      // is the observation's identity and is what the map overlay names.
      Text(repeater.id.uppercased())
        .font(font.monospaced().weight(.semibold))
        .lineLimit(1)
      if showsName, let name = repeater.resolvedName {
        Text(name)
          .font(font)
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
      }
      Spacer(minLength: 4)
      Text(repeater.snr.formattedSnr)
        .font(font.monospacedDigit().weight(.semibold))
        .foregroundStyle(repeater.snrColor.map(Color.init) ?? .secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(repeater.accessibilitySummary)
  }
}

private struct MeshMapperMetrics: View {
  let state: MeshMapperActivityAttributes.ContentState
  let compact: Bool

  var body: some View {
    HStack(spacing: compact ? 9 : 11) {
      Text("\(state.primaryMetricLabel) \(state.primaryMetricValue)")
      Text("RX \(state.rxCount)")
      if state.queueSize > 0 {
        Label("\(state.queueSize)", systemImage: "arrow.triangle.2.circlepath")
      }
    }
    .font(.caption2.monospacedDigit().weight(.medium))
    .foregroundStyle(.secondary)
    .lineLimit(1)
  }
}

private struct MeshMapperIslandBottom: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      MeshMapperPhaseBar(
        state: state,
        height: 18,
        titleFont: .caption.weight(.semibold),
        countdownFont: .caption2.monospacedDigit().weight(.bold),
        countdownWidth: 42
      )
      MeshMapperRepeaterSummary(
        state: state,
        limit: 2,
        showsNames: false,
        rowFont: .caption2
      )
      MeshMapperMetrics(state: state, compact: true)
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
      // Mode is categorical, not signal data. Keeping its badge neutral leaves
      // palette-resolved outcome, type, and SNR colours unambiguous.
      .background(.white.opacity(0.16), in: Capsule())
  }
}

private struct MeshMapperIslandOutcome: View {
  let state: MeshMapperActivityAttributes.ContentState
  let isStale: Bool

  var body: some View {
    if isStale {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(.orange)
        .accessibilityLabel("Update delayed")
    } else {
      HStack(spacing: 5) {
        MeshMapperOutcomeDot(state: state, diameter: 8)
        Text(state.primaryMetricValue.formatted())
          .font(.caption.monospacedDigit().weight(.semibold))
      }
    }
  }
}

private struct MeshMapperOutcomeDot: View {
  let state: MeshMapperActivityAttributes.ContentState
  let diameter: CGFloat

  var body: some View {
    Circle()
      .fill(state.displayColor)
      .frame(width: diameter, height: diameter)
      .accessibilityLabel("Latest ping result")
  }
}

private struct MeshMapperCompactTrailing: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { context in
      if state.hasActiveCountdown(at: context.date) {
        MeshMapperCountdown(
          state: state,
          at: context.date,
          font: .caption2.monospacedDigit().weight(.bold)
        )
        .frame(minWidth: 28)
      } else if let best = state.repeaters.first {
        Text(best.snr.formattedSnr)
          .font(.caption2.monospacedDigit().weight(.bold))
          .foregroundStyle(best.snrColor.map(Color.init) ?? .primary)
          .accessibilityLabel("Best SNR \(best.snr.formattedSnr)")
      } else {
        MeshMapperOutcomeDot(state: state, diameter: 8)
      }
    }
  }
}

private struct MeshMapperCountdown: View {
  let state: MeshMapperActivityAttributes.ContentState
  let at: Date
  let font: Font

  var body: some View {
    if let end = state.phaseEndsAt, end > at {
      Text(timerInterval: at...end, countsDown: true, showsHours: false)
        .font(font)
        .lineLimit(1)
        .accessibilityLabel("Time remaining")
    }
  }
}

private enum MeshMapperPalette {
  static let background = Color(red: 0.055, green: 0.075, blue: 0.105)
}

extension MeshMapperActivityAttributes.ContentState {
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
      return "Nothing heard"
    default:
      return "Nothing heard in the last cycle"
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

  /// Phone-resolved outcome colour wins whenever one exists. System colours
  /// are only a fallback before a session has produced a ping result.
  fileprivate var displayColor: Color {
    if let pingColor { return Color(pingColor) }
    switch phase {
    case "sending", "discovering", "tracing": return .blue
    case "listening", "listening_discovery", "listening_trace": return .teal
    case "waiting", "waiting_discovery", "waiting_trace", "cooldown": return .cyan
    case "skipped", "waiting_for_gps", "paused_outside_zone": return .orange
    case "disconnected", "tx_blocked": return .red
    case "stopped": return .gray
    default: return .white
    }
  }

  fileprivate func hasActiveCountdown(at date: Date) -> Bool {
    guard let phaseEndsAt else { return false }
    return phaseEndsAt > date
  }

  fileprivate func deadlineLapsed(at date: Date) -> Bool {
    guard let phaseEndsAt else { return false }
    return phaseEndsAt <= date
  }

  /// Fraction remaining in the current countdown, calculated locally so the
  /// Live Activity does not need a state update every second.
  fileprivate func phaseRemainingFraction(at date: Date) -> CGFloat? {
    guard let phaseEndsAt, let phaseDurationMs, phaseDurationMs > 0 else {
      return nil
    }
    let remaining = phaseEndsAt.timeIntervalSince(date)
    guard remaining > 0 else { return 0 }
    return CGFloat(min(1, remaining / (Double(phaseDurationMs) / 1000)))
  }
}

extension MeshMapperActivityAttributes.HeardRepeater {
  fileprivate var resolvedName: String? {
    let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    guard !trimmed.isEmpty, trimmed.caseInsensitiveCompare(id) != .orderedSame else {
      return nil
    }
    return trimmed
  }

  fileprivate var accessibilitySummary: String {
    let identity = resolvedName.map { "\(id), \($0)" } ?? id
    return "\(identity), SNR \(snr.formattedSnr)"
  }
}

extension MeshMapperActivityAttributes.ResolvedColor {
  fileprivate var swiftUIColor: Color {
    Color(.sRGB, red: r, green: g, blue: b, opacity: 1)
  }
}

extension Color {
  fileprivate init(_ resolved: MeshMapperActivityAttributes.ResolvedColor) {
    self = resolved.swiftUIColor
  }
}

extension Double {
  fileprivate var formattedSnr: String {
    let sign = self >= 0 ? "+" : ""
    return "\(sign)\(formatted(.number.precision(.fractionLength(1)))) dB"
  }
}

#if DEBUG
extension MeshMapperActivityAttributes.ContentState {
  fileprivate static var previewRunningWithResponses: Self {
    Self(
      mode: "Hybrid",
      phase: "listening",
      phaseTitle: "Listening…",
      phaseDetail: "Waiting for repeater echoes",
      phaseEndsAt: Date().addingTimeInterval(42),
      phaseDurationMs: 60_000,
      pingColor: .init(r: 0.20, g: 0.84, b: 0.45),
      isConnected: true,
      zoneCode: "SEA",
      txCount: 42,
      rxCount: 318,
      discoveryCount: 8,
      traceCount: 0,
      queueSize: 2,
      repeaters: [
        .init(
          id: "A61F",
          name: "Capitol Hill",
          snr: 12.4,
          typeColor: .init(r: 0.20, g: 0.84, b: 0.45),
          snrColor: .init(r: 0.34, g: 0.90, b: 0.44)
        ),
        .init(
          id: "0B73",
          name: "Lake Union",
          snr: 2.1,
          typeColor: .init(r: 0.22, g: 0.80, b: 0.78),
          snrColor: .init(r: 0.96, g: 0.76, b: 0.22)
        ),
        .init(
          id: "91CE",
          name: nil,
          snr: -8.7,
          typeColor: .init(r: 0.64, g: 0.42, b: 0.94),
          snrColor: .init(r: 0.94, g: 0.30, b: 0.28)
        ),
      ],
      totalHeardCount: 5,
      repeatersAreCurrent: true,
      updatedAt: Date()
    )
  }

  fileprivate static var previewRunningWithNoneHeard: Self {
    Self(
      mode: "Active",
      phase: "listening",
      phaseTitle: "Listening…",
      phaseDetail: "Waiting for repeater echoes",
      phaseEndsAt: Date().addingTimeInterval(25),
      phaseDurationMs: 60_000,
      pingColor: .init(r: 0.94, g: 0.28, b: 0.25),
      isConnected: true,
      zoneCode: "SEA",
      txCount: 17,
      rxCount: 3,
      discoveryCount: 0,
      traceCount: 0,
      queueSize: 0,
      repeaters: [],
      totalHeardCount: 0,
      repeatersAreCurrent: true,
      updatedAt: Date()
    )
  }

  fileprivate static var previewLapsedDeadline: Self {
    var state = previewRunningWithResponses
    state.phaseEndsAt = Date().addingTimeInterval(-5)
    state.repeatersAreCurrent = false
    return state
  }
}

private struct MeshMapperActivityPreview: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    ScrollView {
      VStack(spacing: 18) {
        MeshMapperLockScreenContent(state: state, isStale: false)
          .background(MeshMapperPalette.background)
          .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

        // The island's regions are composed by the system at runtime. Showing
        // their shared bottom region here keeps its bar and rows inspectable
        // without requiring a BLE-backed ActivityKit session.
        MeshMapperIslandBottom(state: state)
          .padding(12)
          .foregroundStyle(.white)
          .background(.black)
          .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

        if #available(iOSApplicationExtension 18.0, *) {
          MeshMapperSmallActivityContent(state: state, isStale: false)
            .frame(width: 180)
            .background(MeshMapperPalette.background)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
      }
      .padding()
    }
    .preferredColorScheme(.dark)
  }
}

/// Renders each layout to a PNG so the design can be reviewed without a live
/// session.
///
/// A Live Activity needs ActivityKit to construct its context, and ActivityKit
/// needs a session, which needs BLE — which the simulator does not have. That
/// left three layouts reviewable only on a wrist. The content views take a
/// plain `ContentState`, so `ImageRenderer` can draw them headlessly instead.
///
/// DEBUG-only, and reached solely from a launch argument.
enum MeshMapperActivityRenderHarness {
  /// Widths are the real ones: a Live Activity on the lock screen spans about
  /// 360 pt, the watch's small family about 184, and the island's shared bottom
  /// region about 360.
  @MainActor
  static func writeRenders(to directory: URL) -> [String] {
    let states: [(String, MeshMapperActivityAttributes.ContentState)] = [
      ("responses", .previewRunningWithResponses),
      ("none-heard", .previewRunningWithNoneHeard),
      ("lapsed", .previewLapsedDeadline),
    ]

    var written: [String] = []
    for (name, state) in states {
      written += [
        render(
          MeshMapperLockScreenContent(state: state, isStale: false)
            .frame(width: 360)
            .background(MeshMapperPalette.background),
          named: "lock-\(name)", in: directory
        ),
        render(
          MeshMapperIslandBottom(state: state)
            .padding(12)
            .foregroundStyle(.white)
            .frame(width: 360)
            .background(.black),
          named: "island-\(name)", in: directory
        ),
      ].compactMap { $0 }

      if #available(iOS 18.0, *) {
        if let path = render(
          MeshMapperSmallActivityContent(state: state, isStale: false)
            .frame(width: 184)
            .background(MeshMapperPalette.background),
          named: "small-\(name)", in: directory
        ) {
          written.append(path)
        }
      }
    }
    return written
  }

  @MainActor
  private static func render(
    _ view: some View, named name: String, in directory: URL
  ) -> String? {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .dark))
    renderer.scale = 3
    guard let data = renderer.uiImage?.pngData() else { return nil }
    let url = directory.appendingPathComponent("\(name).png")
    try? data.write(to: url)
    return url.path
  }
}

#Preview("Running — responses") {
  MeshMapperActivityPreview(state: .previewRunningWithResponses)
}

#Preview("Running — none heard") {
  MeshMapperActivityPreview(state: .previewRunningWithNoneHeard)
}

#Preview("Lapsed deadline") {
  MeshMapperActivityPreview(state: .previewLapsedDeadline)
}
#endif
