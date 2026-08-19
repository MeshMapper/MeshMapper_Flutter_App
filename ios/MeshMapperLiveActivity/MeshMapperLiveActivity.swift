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
        .foregroundStyle(context.isStale ? Color.orange : context.state.phaseColor)
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
      // The keyline is container chrome, not a second outcome indicator. A
      // failed ping is routine and should not turn the whole island red.
      .keylineTint(MeshMapperPalette.accent)
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

/// The watch Smart Stack card.
///
/// **It is a widget-sized card, not a lock-screen banner**: 152x69.5 pt on a
/// 40 mm watch through 191x81.5 pt on a 49 mm one, per the HIG's watchOS
/// widget dimensions.
///
/// **One header line, then the observations.** The phase names itself on the
/// left; mode, latest outcome and zone sit at the right of that same line,
/// where they cost no line of their own. Everything under it is the map page's
/// Top Heard block — `[type dot] [hex ID] [SNR]` in two columns, column-major,
/// four observations deep.
///
/// **What it deliberately no longer carries.** The countdown is gone: a
/// `Text(timerInterval:)` is redrawn by the system every second it is visible,
/// and the display is where this app's marginal energy goes on the wrist — a
/// measured 80 % of it. The phase title already says what is happening, and
/// the exact second it ends is not a wrist-glance fact. The heard-summary line
/// went with it, and the session counters that shared it. `repeatersAreCurrent`
/// still reaches the wearer as the grid's opacity, which is where that fact was
/// already carried on cards too narrow to spell it out.
///
/// **Both dimensions are measured rather than assumed.** This view is rendered
/// by the iOS extension and mirrored to the wrist, so `WKInterfaceDevice`
/// screen bounds — which size the equivalent panel in `MapPage` — are not
/// reachable from here. The `GeometryReader` hands the row solver the card's
/// real width *and* the height left under the header, so the type is as large
/// as the smaller of the two allows. Height alone cannot enlarge it: at these
/// widths the rows are width-bound, which is why freeing two lines buys
/// headroom for the cap rather than bigger type on its own.
@available(iOSApplicationExtension 18.0, *)
private struct MeshMapperSmallActivityContent: View {
  let state: MeshMapperActivityAttributes.ContentState
  let isStale: Bool

  /// Matches the map panel's own insets. The card has rounded corners the
  /// system draws, so the horizontal value is clearance, not decoration.
  private static let horizontalPadding: CGFloat = 8
  private static let verticalPadding: CGFloat = 5
  private static let headerSpacing: CGFloat = 4
  /// The 13 pt semibold title's line height, pinned rather than measured so
  /// the height the row solver is given and the height the header actually
  /// takes cannot drift apart.
  private static let headerHeight: CGFloat = 16

  var body: some View {
    GeometryReader { geo in
      let layout = MeshMapperHeardLayout(
        contentWidth: geo.size.width - 2 * Self.horizontalPadding,
        contentHeight: geo.size.height - 2 * Self.verticalPadding
          - Self.headerHeight - Self.headerSpacing,
        repeaters: state.repeaters
      )
      VStack(alignment: .leading, spacing: Self.headerSpacing) {
        headerLine
          .frame(height: Self.headerHeight)
        MeshMapperHeardGrid(state: state, layout: layout)
          // Rows from a finished cycle are still worth showing, but they are
          // not a claim about now. With the summary line gone this opacity is
          // the only thing left saying so, which it already was on the cards
          // that never had room for the words.
          .opacity(state.repeatersAreCurrent ? 1 : 0.55)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .padding(.horizontal, Self.horizontalPadding)
      .padding(.vertical, Self.verticalPadding)
    }
    .foregroundStyle(.white)
  }

  /// Phase on the left, session identity on the right.
  ///
  /// Staleness replaces the phase title rather than sitting beside it, as it
  /// does in the map panel: a phase that nobody is refreshing should not keep
  /// announcing itself, and the swap costs no width the right side needs.
  private var headerLine: some View {
    HStack(spacing: 4) {
      if isStale {
        Label("Update delayed", systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(.orange)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      } else {
        Text(state.phaseTitle)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(.white.opacity(state.phaseDeadlineHasLapsed ? 0.45 : 1))
          .lineLimit(1)
          // Shrink before truncating. Sharing the line with the mode leaves
          // "Listening…" about four points short on a 40 mm card, and a title
          // clipped to "Liste…" reads as a different word; a title one point
          // smaller reads as the same one.
          .minimumScaleFactor(0.8)
          .truncationMode(.tail)
      }
      Spacer(minLength: 4)
      trailingIdentity
    }
  }

  /// Mode, latest outcome and zone — the facts that used to own the bottom
  /// line. They are `fixedSize` so the phase title, which can be truncated
  /// without becoming wrong, is what gives way on a narrow card.
  private var trailingIdentity: some View {
    HStack(spacing: 4) {
      Text(state.mode.uppercased())
        .font(.system(size: 10, weight: .bold))
        .tracking(0.3)
      MeshMapperOutcomeDot(state: state, diameter: 6)
      if let zone = state.zoneCode {
        Text(zone)
          .font(.system(size: 10, weight: .semibold, design: .monospaced))
      } else if !state.isConnected {
        Text("Disconnected")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.orange)
      }
    }
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
  }
}

/// The map panel's Top Heard block, rendered from Live Activity state.
///
/// Rows are `[type dot] [hex ID] [SNR]` and read down the left column before
/// the right, matching `MapPage.statusPanel`. The hex path hash stays primary
/// and unabbreviated: a 1-byte hash is frequently ambiguous, so it — not a
/// resolved name — is the observation's identity, and names are dropped here
/// rather than truncated.
@available(iOSApplicationExtension 18.0, *)
private struct MeshMapperHeardGrid: View {
  let state: MeshMapperActivityAttributes.ContentState
  let layout: MeshMapperHeardLayout

  var body: some View {
    if state.repeaters.isEmpty {
      HStack(spacing: 6) {
        // A failed ping produces no rows, so its colour needs its own mark;
        // absence alone cannot distinguish failure from no attempt yet.
        MeshMapperOutcomeDot(state: state, diameter: 6)
        Text("Nothing heard")
          .font(.system(size: 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
    } else if layout.usesTwoColumns {
      HStack(alignment: .top, spacing: MeshMapperHeardLayout.columnGap) {
        column(Array(rows.prefix(2)))
        column(Array(rows.dropFirst(2)))
      }
    } else {
      column(rows)
    }
  }

  /// Four rows are what two columns hold; one column keeps the two it can show
  /// without pushing the lines below it off the card.
  private var rows: [MeshMapperActivityAttributes.HeardRepeater] {
    Array(state.repeaters.prefix(layout.usesTwoColumns ? 4 : 2))
  }

  private func column(
    _ repeaters: [MeshMapperActivityAttributes.HeardRepeater]
  ) -> some View {
    VStack(alignment: .leading, spacing: MeshMapperHeardLayout.rowGap) {
      ForEach(repeaters) { row($0) }
    }
  }

  /// Content-sized on purpose, so the row's intrinsic measurement stays equal
  /// to the width model that chose the font and the column count.
  private func row(
    _ repeater: MeshMapperActivityAttributes.HeardRepeater
  ) -> some View {
    HStack(spacing: 3) {
      Circle()
        .fill(repeater.typeColor.map(Color.init) ?? state.outcomeColor)
        .frame(width: 6, height: 6)
      Text(repeater.id.uppercased())
        .font(
          .system(size: layout.rowFontSize, weight: .semibold, design: .monospaced)
        )
      // No unit and no plus sign, as on the map panel: the column is all SNR,
      // and "dB" on every row costs the width a fourth observation needs.
      Text(repeater.snr, format: .number.precision(.fractionLength(1)))
        .font(
          .system(size: layout.rowFontSize, weight: .semibold, design: .monospaced)
        )
        .foregroundStyle(repeater.snrColor.map(Color.init) ?? .secondary)
        // Fixed width so SNRs line up down a column despite varying digits.
        .frame(width: layout.rowFontSize * layout.snrWidthEm, alignment: .trailing)
    }
    .lineLimit(1)
    .fixedSize()
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(repeater.accessibilitySummary)
  }
}

/// Column count and row font, solved from the card's measured width the way
/// `MapPage` solves them from the watch's screen bounds.
@available(iOSApplicationExtension 18.0, *)
private struct MeshMapperHeardLayout {
  /// A stable gutter keeps the width equation and the rendered columns in
  /// agreement; deriving it from card size would silently spend the room the
  /// font calculation just recovered on the smallest watch.
  static let columnGap: CGFloat = 8
  /// Vertical gap between the two rows of a column.
  static let rowGap: CGFloat = 2
  /// Advance of one semibold monospaced character, in ems. Closer to 0.62 than
  /// the nominal 0.6, measured off the rendered row.
  private static let charAdvance: CGFloat = 0.62
  /// A rendered line box against its nominal point size, for the height bound.
  private static let lineHeightRatio: CGFloat = 1.25

  let usesTwoColumns: Bool
  let rowFontSize: CGFloat
  /// Width of the aligned SNR column, in ems of `rowFontSize`. Solved from the
  /// widest value actually present rather than from the widest one possible:
  /// a fixed five-character reservation charged every card for "-12.4" when
  /// the data was "2.1", and that reservation was the single largest consumer
  /// of the width the type needed.
  let snrWidthEm: CGFloat

  init(
    contentWidth: CGFloat,
    contentHeight: CGFloat,
    repeaters: [MeshMapperActivityAttributes.HeardRepeater]
  ) {
    let idChars = CGFloat(repeaters.map(\.id.count).max() ?? 2)
    let snrChars = CGFloat(repeaters.map { Self.snrCharacterCount($0.snr) }.max() ?? 4)
    snrWidthEm = Self.charAdvance * snrChars

    let columnWidth = (contentWidth - Self.columnGap) / 2 - 2
    // The constants mirror the row: dot and its two gaps consume 12 pt, and
    // both text runs advance at `charAdvance`. Two points of slack put
    // measurement error on smaller type rather than on a row that overflows.
    let widthBound =
      (columnWidth - 12) / (Self.charAdvance * idChars + snrWidthEm)

    // Eight points is the wrist's measured glanceability floor and is
    // inherited unchanged — below it the extra width stops paying for itself
    // and one clearer column wins. Truncating the ID is never the trade,
    // because the ID is the identity.
    usesTwoColumns = widthBound >= 8

    // Two rows deep either way: two columns hold four, one column keeps the
    // two it can show. Type that overflows this is the defect the card was
    // rebuilt to fix, so the height is a bound and not a preference.
    let heightBound =
      (contentHeight - Self.rowGap) / 2 / Self.lineHeightRatio

    // Raised now that the header is the only line above the grid. The card is
    // wider than the app's panel and has no map beneath it to stay clear of,
    // so the same arm's-length reading distance affords larger type here; the
    // ladder still steps down as the ID lengthens, because a longer ID spends
    // the same width on identity that the size would otherwise take.
    let cap: CGFloat = idChars > 4 ? 14 : idChars > 2 ? 15 : 16
    let bound = min(usesTwoColumns ? widthBound : cap, heightBound)
    rowFontSize = min(max(bound, 8), cap)
  }

  /// Characters in an SNR as the row formats it: one fraction digit, its
  /// separator, the integer digits, and a minus sign when there is one. The
  /// monospaced face advances all of them equally, so counting them is the
  /// same measurement the ID gets.
  private static func snrCharacterCount(
    _ snr: Double
  ) -> Int {
    let magnitude = abs(snr)
    let integerDigits = magnitude < 10 ? 1 : magnitude < 100 ? 2 : 3
    return integerDigits + 2 + (snr < 0 ? 1 : 0)
  }
}

/// The phase as a caption, a native countdown, and system-drawn progress.
///
/// **Nothing here animates and nothing here holds state.** It used to: a
/// `@State` fraction was driven to zero by a `withAnimation` lasting the whole
/// phase, which a Live Activity cannot honour. Widgets cap a custom animation
/// at two seconds and run none at all under reduced luminance, so on an
/// always-on lock screen the fill simply stayed wherever the last ActivityKit
/// update left it — observed still nearly full with nine seconds on the clock.
///
/// Both elements are now derived from absolute dates by the system, so every
/// render the system chooses to make, on whatever schedule it likes, lands in
/// the right place — and none of them costs this extension any work.
private struct MeshMapperPhaseBar: View {
  let state: MeshMapperActivityAttributes.ContentState
  let titleFont: Font
  let countdownFont: Font
  let countdownWidth: CGFloat

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(spacing: 4) {
        Text(state.phaseTitle)
          .font(titleFont)
          .foregroundStyle(.white.opacity(state.phaseDeadlineHasLapsed ? 0.45 : 1))
          .lineLimit(1)
          .truncationMode(.tail)
        Spacer(minLength: 4)
        // Fixed width because the native timer otherwise reserves room for its
        // widest possible value and starves the title.
        MeshMapperCountdown(state: state, font: countdownFont)
          .frame(width: countdownWidth, alignment: .trailing)
      }
      MeshMapperPhaseProgress(state: state)
    }
  }
}

/// Elapsed phase progress, drawn by the system from the phase's own dates.
///
/// The range is the **whole phase**, not `now...deadline`: a range beginning at
/// the current render would reset the bar to empty every time the system
/// redrew the activity, which is the failure the hand-animated fill had in a
/// different form.
///
/// It fills rather than drains, which is the trade for handing the work to
/// `ProgressView`. The countdown beside it remains the authoritative statement
/// of time remaining; the bar is the glanceable one.
private struct MeshMapperPhaseProgress: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    if let range = state.phaseProgressRange {
      ProgressView(timerInterval: range, countsDown: false) {
        EmptyView()
      } currentValueLabel: {
        EmptyView()
      }
      .progressViewStyle(.linear)
      // Progress says how far through the phase we are. Outcome has quieter,
      // dedicated dots elsewhere and must not recolour the whole track.
      .tint(MeshMapperPalette.accent)
    } else {
      // A durable state — disconnected, stopped, waiting for GPS — has no
      // deadline to draw. The empty track keeps the block's height fixed, so
      // arriving at one cannot reflow everything below it.
      Capsule()
        .fill(.white.opacity(0.16))
        .frame(height: Self.trackHeight)
    }
  }

  /// Matches the linear `ProgressView` track this stands in for.
  private static let trackHeight: CGFloat = 4
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
            fallbackColor: state.outcomeColor,
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
  /// Both defaulted so the lock screen and the island keep what they had. The
  /// watch card overrides them to share a line with the heard-list summary,
  /// where the queue is the first thing worth giving up for the room.
  var font: Font = .caption2.monospacedDigit().weight(.medium)
  var showsQueue: Bool = true

  var body: some View {
    HStack(spacing: compact ? 9 : 11) {
      Text("\(state.primaryMetricLabel) \(state.primaryMetricValue)")
      Text("RX \(state.rxCount)")
      if showsQueue, state.queueSize > 0 {
        Label("\(state.queueSize)", systemImage: "arrow.triangle.2.circlepath")
      }
    }
    .font(font)
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
      .fill(state.outcomeColor)
      .frame(width: diameter, height: diameter)
      .accessibilityLabel("Latest ping result")
  }
}

/// **No state and no task**, for the reason `MeshMapperPhaseBar` states above:
/// WidgetKit renders these views out of process and the extension "is not
/// continually active, even if the widget is onscreen", so a `@State` flag
/// retired by a sleeping `Task.sleep` is a promise this context cannot keep.
///
/// Nothing is lost by dropping it. `activeCountdownRange` is evaluated on every
/// render and already returns nil once the deadline passes, so the branch below
/// falls through to the SNR or the outcome dot exactly when it should — using
/// the clock the system re-reads for us rather than a flag we hoped to update.
private struct MeshMapperCompactTrailing: View {
  let state: MeshMapperActivityAttributes.ContentState

  var body: some View {
    if state.activeCountdownRange != nil {
      MeshMapperCountdown(
        state: state,
        isActive: true,
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

private struct MeshMapperCountdown: View {
  let state: MeshMapperActivityAttributes.ContentState
  var isActive: Bool = true
  let font: Font

  var body: some View {
    if isActive, let range = state.activeCountdownRange {
      Text(timerInterval: range, countsDown: true, showsHours: false)
        .font(font)
        .lineLimit(1)
        .accessibilityLabel("Time remaining")
    }
  }
}

private enum MeshMapperPalette {
  static let background = Color(red: 0.055, green: 0.075, blue: 0.105)
  static let accent = Color.accentColor
}

extension MeshMapperActivityAttributes.ContentState {
  fileprivate var activeCountdownRange: ClosedRange<Date>? {
    let now = Date()
    guard let phaseEndsAt, phaseEndsAt > now else { return nil }
    return now...phaseEndsAt
  }

  /// The phase's own span, for a `ProgressView` that reads the clock itself.
  ///
  /// Deliberately anchored to the phase's start rather than to `now`, so a
  /// system-initiated redraw resumes the bar where the clock says it is
  /// instead of restarting it.
  fileprivate var phaseProgressRange: ClosedRange<Date>? {
    guard let phaseEndsAt, let phaseDurationMs, phaseDurationMs > 0 else {
      return nil
    }
    let start = phaseEndsAt.addingTimeInterval(-Double(phaseDurationMs) / 1000)
    guard start < phaseEndsAt else { return nil }
    return start...phaseEndsAt
  }

  /// Evaluated at render time rather than retired by a sleeping task: a widget
  /// that is not being redrawn has no one to show the change to, and the phase
  /// transition that follows a deadline arrives as an urgent update anyway.
  fileprivate var phaseDeadlineHasLapsed: Bool {
    guard let phaseEndsAt else { return false }
    return phaseEndsAt <= Date()
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

  /// Phone-resolved outcome colour wins whenever one exists. The phase colour
  /// is only a fallback before a session has produced a ping result.
  fileprivate var outcomeColor: Color {
    if let pingColor { return Color(pingColor) }
    return phaseColor
  }

  /// Colour for an element that describes the current phase rather than the
  /// result of the most recent ping.
  fileprivate var phaseColor: Color {
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
        // A fourth, because the Smart Stack card draws two columns by two rows
        // and a three-row sample cannot show the grid it has to fit.
        .init(
          id: "5E02",
          name: "Beacon Hill",
          snr: 6.8,
          typeColor: .init(r: 0.20, g: 0.84, b: 0.45),
          snrColor: .init(r: 0.34, g: 0.90, b: 0.44)
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
          // Both ends of the watch range, because the card's row solver and
          // its `ViewThatFits` ladder can only be reviewed against real sizes.
          ForEach(MeshMapperSmartStackSize.allCases, id: \.self) { size in
            MeshMapperSmallActivityContent(state: state, isStale: false)
              .frame(width: size.width, height: size.height)
              .background(MeshMapperPalette.background)
              .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
          }
        }
      }
      .padding()
    }
    .preferredColorScheme(.dark)
  }
}

/// The Smart Stack card at both ends of the watch range, from the HIG's
/// watchOS widget dimensions. A card this view is reviewed in must be given a
/// height: overflowing it is the defect being guarded against, and a harness
/// that lets the content pick its own height cannot show that.
enum MeshMapperSmartStackSize: CaseIterable {
  /// 40 mm — the smallest card, and the one the ladder must still fit.
  case small
  /// 49 mm — the largest, where the summary and mode lines earn their place.
  case large

  var label: String {
    switch self {
    case .small: return "40mm"
    case .large: return "49mm"
    }
  }

  var width: CGFloat {
    switch self {
    case .small: return 152
    case .large: return 191
    }
  }

  var height: CGFloat {
    switch self {
    case .small: return 69.5
    case .large: return 81.5
    }
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
/// **`ImageRenderer` cannot draw the phase progress bar, and its failure looks
/// like a bug in the bar.** A `ProgressView(timerInterval:)` comes out as a
/// full-width track with a no-entry glyph in the middle, identically at every
/// remaining fraction — `Text(timerInterval:)` beside it snapshots fine, which
/// makes the difference easy to misread as ours. Hosting the same views in a
/// live `UIHostingController` in the simulator draws them correctly and
/// advances them with no state update at all: 0:40 of a 60 s phase at 33 %,
/// 0:23 at 62 %, 0:05 at 92 %. Review the bar that way, not through here.
///
/// DEBUG-only, and reached solely from a launch argument.
enum MeshMapperActivityRenderHarness {
  /// Sizes are the real ones: a Live Activity on the lock screen spans about
  /// 360 pt, the island's shared bottom region about 360, and the watch's small
  /// family a Smart Stack card — whose height is the constraint, so it is given
  /// rather than left to the content to choose.
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
        for size in MeshMapperSmartStackSize.allCases {
          if let path = render(
            MeshMapperSmallActivityContent(state: state, isStale: false)
              .frame(width: size.width, height: size.height)
              .background(MeshMapperPalette.background),
            named: "small-\(size.label)-\(name)", in: directory
          ) {
            written.append(path)
          }
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
