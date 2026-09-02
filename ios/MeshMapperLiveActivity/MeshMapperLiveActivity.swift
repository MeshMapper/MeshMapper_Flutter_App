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

/// The small activity family card: the watch Smart Stack and, on iOS 26,
/// the CarPlay dashboard.
///
/// **The layout is a band over rows.** A slate band carries the session's
/// status facts (phase on the left, mode and zone in the middle, noise floor
/// and battery pinned to the far right, each beside its app icon) above a
/// hairline divider, and the body below is up to three named repeater rows.
///
/// **Width decides how much the band spells out.** The watch card is
/// 152–191 pt wide per the HIG's watchOS widget dimensions; CarPlay's is
/// wider. Past 200 pt the band adds the mode word and the battery percentage,
/// and the body targets three rows (the hex grid three per column, six in
/// all); under it the icons carry the middle, the battery keeps only its
/// glyph (until it runs low), and two rows fit.
///
/// **Height decides the row type size.** CarPlay picks the canvas it renders
/// the card into, and it is not the same canvas every drive; fixed row fonts
/// clipped the last row whenever the canvas came up short. The body solves
/// its row font (and the grid its depth) from the measured box, so the
/// target rows always land whole: smaller-but-complete, never
/// bigger-but-clipped.
///
/// **No ticking countdown in this family, on any width.** A
/// `Text(timerInterval:)` is redrawn by the system every second it is
/// visible: on the wrist that redraw was measured at 80 % of this app's
/// display energy, and the iOS 26.6 CarPlay dashboard renders the whole card
/// as a blank tile whenever the state carries one, recovering only in the
/// phases without a deadline. Nothing here holds state or animates, and
/// `repeatersAreCurrent` still reaches the reader as the rows' opacity.
///
/// **The name is the only elastic element in a row.** The hex ID stays the
/// observation's identity (a 1-byte hash is frequently ambiguous) and the SNR
/// keeps its width and alignment, so a long resolved name truncates between
/// them rather than disturbing either.
@available(iOSApplicationExtension 18.0, *)
private struct MeshMapperSmallActivityContent: View {
  let state: MeshMapperActivityAttributes.ContentState
  let isStale: Bool

  /// Watch cards top out at 191 pt; anything wider is a surface (CarPlay)
  /// that can afford the spelled-out band and the third row.
  private static let wideThreshold: CGFloat = 200

  /// Width past which the band can afford the spelled-out mode word on top
  /// of everything else it carries.
  private static let modeWordThreshold: CGFloat = 280

  var body: some View {
    GeometryReader { geo in
      let isWide = geo.size.width >= Self.wideThreshold
      let showsModeWord = geo.size.width >= Self.modeWordThreshold
      VStack(alignment: .leading, spacing: 0) {
        headerBand(isWide: isWide, showsModeWord: showsModeWord)
        // The rows solve their font from this measured box: CarPlay varies
        // the canvas it renders the card into between drives, and fixed row
        // sizes clipped the last row whenever the canvas came up short.
        GeometryReader { rowsBox in
          heardRows(isWide: isWide, size: rowsBox.size)
            // Rows from a finished cycle are still worth showing, but they are
            // not a claim about now; the dimming is that statement.
            .opacity(state.repeatersAreCurrent ? 1 : 0.55)
        }
        .padding(.horizontal, isWide ? 12 : 7)
        .padding(.vertical, isWide ? 6 : 4)
      }
    }
    .foregroundStyle(.white)
  }

  // MARK: Row solving

  /// Generous line height for SF at a given point size: ascender, descender
  /// and the row's breathing room.
  private static let rowLineFactor: CGFloat = 1.3

  /// Below this the type stops paying for itself; a row that cannot render at
  /// 8 pt whole is a row the card should not attempt.
  private static let minRowFont: CGFloat = 8

  /// How many of [target] rows fit [height] with every row whole at the
  /// readability floor. Clipping the last row is the defect this guards.
  private static func rowsThatFit(
    target: Int, height: CGFloat, gap: CGFloat
  ) -> Int {
    let minRow = minRowFont * rowLineFactor
    let fit = Int((height + gap) / (minRow + gap))
    return max(1, min(target, fit))
  }

  /// The largest row font that seats [count] rows in [height], clamped to the
  /// tier's cap and the readability floor.
  private static func rowFont(
    count: Int, height: CGFloat, gap: CGFloat, cap: CGFloat
  ) -> CGFloat {
    guard count > 0 else { return cap }
    let rowHeight = (height - gap * CGFloat(count - 1)) / CGFloat(count)
    return min(max(rowHeight / rowLineFactor, minRowFont), cap)
  }

  // MARK: Header band

  private func headerBand(isWide: Bool, showsModeWord: Bool) -> some View {
    HStack(spacing: isWide ? 5 : 2) {
      if isStale {
        Label("Update delayed", systemImage: "exclamationmark.triangle.fill")
          .font(.system(size: isWide ? 12 : 11, weight: .semibold))
          .foregroundStyle(.orange)
          .lineLimit(1)
          .minimumScaleFactor(0.85)
      } else if isWide {
        Text(state.bandPhaseTitle)
          .font(.system(size: 13, weight: .semibold))
          .foregroundStyle(
            state.phaseColor.opacity(state.phaseDeadlineHasLapsed ? 0.45 : 1)
          )
          .lineLimit(1)
          // Shrink before truncating: a title clipped to "Liste…" reads as a
          // different word; a title one point smaller reads as the same one.
          .minimumScaleFactor(0.7)
          .truncationMode(.tail)
          .layoutPriority(1)
        // No countdown beside the title: the CarPlay dashboard blanks the
        // whole card while the state carries an auto-updating timer. See the
        // type comment.
      } else {
        // The watch band: the logo carries identity and a single word carries
        // state. A forward-looking title like "Next ping" read as orphaned
        // there with no countdown beside it, which testers called out.
        MeshMapperLogoMark(size: 14)
        Text(state.narrowStatusWord)
          .font(.system(size: 11, weight: .semibold))
          .foregroundStyle(
            state.phaseColor.opacity(state.phaseDeadlineHasLapsed ? 0.45 : 1)
          )
          .lineLimit(1)
          // "Listening" is the longest word and the only one that needs the
          // deeper floor; the short outcome words render at full size.
          .minimumScaleFactor(0.65)
          .layoutPriority(1)
      }
      Spacer(minLength: 4)
      middleIdentity(isWide: isWide, showsModeWord: showsModeWord)
      Spacer(minLength: 4)
      trailingHealth(isWide: isWide, showsModeWord: showsModeWord)
    }
    .padding(.horizontal, isWide ? 12 : 7)
    .padding(.vertical, isWide ? 6 : 4)
    .background(MeshMapperPalette.surface)
    .overlay(alignment: .bottom) {
      Rectangle()
        .fill(MeshMapperPalette.hairline)
        .frame(height: 0.5)
    }
  }

  /// Mode and zone, each beside the icon the app itself uses for it. Narrow
  /// cards drop the mode word and let the icon carry it.
  private func middleIdentity(isWide: Bool, showsModeWord: Bool) -> some View {
    HStack(spacing: isWide ? 4 : 3) {
      // The mode icon earns its place only beside the wide band's title; on
      // the watch the logo owns identity and the zone reads better bigger.
      if isWide {
        Image(systemName: state.modeSymbol)
          .font(.system(size: 9, weight: .bold))
      }
      if showsModeWord {
        Text(state.mode.uppercased())
          .font(.system(size: 10, weight: .bold))
          .tracking(0.3)
      }
      if let zone = state.zoneCode {
        // The pin is the least informative pixel on the 40 mm card, and its
        // width is exactly what "Listening" needs to render unclipped.
        if isWide {
          Image(systemName: "mappin.and.ellipse")
            .font(.system(size: 9, weight: .bold))
        }
        Text(zone)
          .font(.system(size: isWide ? 10 : 9, weight: .semibold, design: .monospaced))
      } else if !state.isConnected {
        Text("Disconnected")
          .font(.system(size: isWide ? 10 : 9, weight: .semibold))
          .foregroundStyle(.orange)
      }
    }
    .foregroundStyle(.secondary)
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
  }

  /// Noise floor and companion battery, pinned to the band's far right. Both
  /// are optional payload fields, so a radio that has not answered a stats
  /// poll simply leaves the slot empty.
  private func trailingHealth(isWide: Bool, showsModeWord: Bool) -> some View {
    HStack(spacing: isWide ? 4 : 3) {
      if let noiseFloor = state.noiseFloorDbm {
        HStack(spacing: 2) {
          Image(systemName: "waveform")
            .font(.system(size: isWide ? 9 : 8, weight: .bold))
          Text("\(noiseFloor)")
            .font(.system(size: isWide ? 10 : 9, weight: .bold, design: .monospaced))
        }
        .foregroundStyle(Self.noiseFloorColor(noiseFloor))
      }
      if let battery = state.companionBatteryPct {
        HStack(spacing: 2) {
          Image(systemName: Self.batterySymbol(battery))
            .font(.system(size: isWide ? 10 : 9, weight: .semibold))
          // The number earns its width only on the widest tier; below it
          // the glyph is the signal, turning red when the battery is in
          // trouble, and the number's width belongs to the status word.
          if showsModeWord {
            Text("\(battery)")
              .font(.system(size: isWide ? 10 : 9, weight: .bold, design: .monospaced))
          }
        }
        .foregroundStyle(battery < 20 ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
      }
    }
    .lineLimit(1)
    .fixedSize(horizontal: true, vertical: false)
  }

  /// The noise floor graph's own thresholds: quiet green to -100 dBm, busy
  /// orange to -90, loud red past it.
  private static func noiseFloorColor(_ dbm: Int) -> Color {
    if dbm <= -100 { return .green }
    if dbm <= -90 { return .orange }
    return .red
  }

  private static func batterySymbol(_ percent: Int) -> String {
    switch percent {
    case 90...: return "battery.100"
    case 60..<90: return "battery.75"
    case 35..<60: return "battery.50"
    case 10..<35: return "battery.25"
    default: return "battery.0"
    }
  }

  // MARK: Heard rows

  @ViewBuilder
  private func heardRows(isWide: Bool, size: CGSize) -> some View {
    if state.repeaters.isEmpty {
      HStack(spacing: 6) {
        // A failed ping produces no rows, so its colour needs its own mark;
        // absence alone cannot distinguish failure from no attempt yet.
        MeshMapperOutcomeDot(state: state, diameter: 6)
        Text(state.repeaterEmptyLabel)
          .font(.system(size: isWide ? 12 : 11))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .minimumScaleFactor(0.75)
      }
    } else if state.showRepeaterNames ?? true {
      let gap: CGFloat = isWide ? 3 : 2
      let count = Self.rowsThatFit(
        target: isWide ? 3 : 2, height: size.height, gap: gap)
      let font = Self.rowFont(
        count: count, height: size.height, gap: gap, cap: isWide ? 13 : 10)
      VStack(alignment: .leading, spacing: gap) {
        ForEach(state.repeaters.prefix(count)) { repeater in
          namedRow(repeater, isWide: isWide, fontSize: font)
        }
      }
    } else {
      hexGrid(isWide: isWide, size: size)
    }
  }

  /// The nameless alternative behind the Settings switch: `[dot hex SNR]`
  /// packed two columns wide, column-major, up to three observations deep per
  /// column on the wide card (six total) and two on the watch. More repeaters
  /// per glance, no identity beyond the hex.
  ///
  /// Font, column count and depth are solved from the measured box: rigid
  /// rows at a fixed size overflowed the 40 mm card as soon as 3-byte path
  /// mode produced 6-character IDs, and overflow the wide card whenever
  /// CarPlay hands it a short canvas.
  private func hexGrid(isWide: Bool, size: CGSize) -> some View {
    let gap: CGFloat = isWide ? 3 : 2
    let perColumn = Self.rowsThatFit(
      target: isWide ? 3 : 2, height: size.height, gap: gap)
    let rows = Array(state.repeaters.prefix(perColumn * 2))
    let columnGap: CGFloat = isWide ? 16 : 8
    let idChars = CGFloat(rows.map { $0.id.count }.max() ?? 2)
    let snrChars = CGFloat(
      rows.map { Self.formattedRowSnr($0.snr, signed: false).count }.max() ?? 4
    )
    // Advance of one semibold monospaced character is about 0.62 em; the dot
    // and its two gaps consume about 12 points of each column.
    let columnWidth = (size.width - columnGap) / 2 - 2
    let widthBound = (columnWidth - 12) / (0.62 * (idChars + snrChars))
    // Below 8 points the type stops paying for itself and one clearer column
    // wins. Truncating the ID is never the trade: the ID is the identity.
    let usesTwoColumns = widthBound >= 8
    let cap: CGFloat = isWide ? 13 : 10
    let heightBound = Self.rowFont(
      count: perColumn, height: size.height, gap: gap, cap: cap)
    let fontSize = min(
      max(usesTwoColumns ? min(widthBound, heightBound) : heightBound, 8), cap)

    return HStack(alignment: .top, spacing: columnGap) {
      hexColumn(Array(rows.prefix(perColumn)), isWide: isWide, fontSize: fontSize)
      if usesTwoColumns, rows.count > perColumn {
        hexColumn(
          Array(rows.dropFirst(perColumn)), isWide: isWide, fontSize: fontSize)
      }
    }
  }

  private func hexColumn(
    _ repeaters: [MeshMapperActivityAttributes.HeardRepeater],
    isWide: Bool,
    fontSize: CGFloat
  ) -> some View {
    VStack(alignment: .leading, spacing: isWide ? 3 : 2) {
      ForEach(repeaters) { repeater in
        HStack(spacing: isWide ? 5 : 3) {
          Circle()
            .fill(repeater.typeColor.map(Color.init) ?? state.outcomeColor)
            .frame(width: isWide ? 6 : 5, height: isWide ? 6 : 5)
          Text(repeater.id.uppercased())
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
          Text(Self.formattedRowSnr(repeater.snr, signed: false))
            .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
            .foregroundStyle(repeater.snrColor.map(Color.init) ?? .secondary)
        }
        .lineLimit(1)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(repeater.accessibilitySummary)
      }
    }
  }

  /// `[type dot] [hex] [name] … [SNR]`. The font arrives height-solved so the
  /// row column always lands whole.
  private func namedRow(
    _ repeater: MeshMapperActivityAttributes.HeardRepeater,
    isWide: Bool,
    fontSize: CGFloat
  ) -> some View {
    HStack(spacing: isWide ? 6 : 4) {
      Circle()
        .fill(repeater.typeColor.map(Color.init) ?? state.outcomeColor)
        .frame(width: isWide ? 6 : 5, height: isWide ? 6 : 5)
      Text(repeater.id.uppercased())
        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
        .fixedSize()
      if let name = repeater.resolvedName {
        Text(name)
          .font(.system(size: max(fontSize - 1, 7)))
          .foregroundStyle(.secondary)
          .lineLimit(1)
          .truncationMode(.tail)
          // The one element that gives way when the row runs out of width.
          .layoutPriority(-1)
      }
      Spacer(minLength: 4)
      Text(Self.formattedRowSnr(repeater.snr, signed: isWide))
        .font(.system(size: fontSize, weight: .semibold, design: .monospaced))
        .foregroundStyle(repeater.snrColor.map(Color.init) ?? .secondary)
        .fixedSize()
    }
    .lineLimit(1)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(repeater.accessibilitySummary)
  }

  /// No unit, as on the map panel: the column is all SNR, and "dB" on every
  /// row costs width the name needs. The narrow card also drops the plus sign.
  private static func formattedRowSnr(_ snr: Double, signed: Bool) -> String {
    let value = snr.formatted(.number.precision(.fractionLength(1)))
    return signed && snr >= 0 ? "+\(value)" : value
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
      // The bar wears the running mode's identity color, phone-resolved from
      // the same ping palette as the app's markers (so CVD palettes carry
      // over). Outcome still lives in the dots: a failed ping must not turn
      // the whole track red, which is why this is mode, not result.
      .tint(state.modeColor.map(Color.init) ?? MeshMapperPalette.accent)
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

/// The app mark for the watch band. Falls back to a drawn monogram when the
/// asset cannot load, so the slot never renders empty.
private struct MeshMapperLogoMark: View {
  let size: CGFloat

  var body: some View {
    if let image = UIImage(named: "LiveActivityLogo") {
      Image(uiImage: image)
        .resizable()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
    } else {
      RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
        .fill(MeshMapperPalette.accent)
        .frame(width: size, height: size)
        .overlay {
          Text("MM")
            .font(.system(size: size * 0.42, weight: .heavy))
            .foregroundStyle(.white)
        }
    }
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
  /// slate-900, the app's main dark background.
  static let background = Color(red: 0.059, green: 0.090, blue: 0.165)
  /// slate-800, the app's card and panel surface, used for the small card's band.
  static let surface = Color(red: 0.118, green: 0.161, blue: 0.231)
  /// slate-700, the app's border colour, used for the band's divider.
  static let hairline = Color(red: 0.200, green: 0.255, blue: 0.333)
  /// emerald-600, the app's primary.
  static let accent = Color(red: 0.020, green: 0.588, blue: 0.412)
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

  /// The phase title without its trailing ellipsis, for the small card's
  /// band: the countdown beside it already says "in progress", and the dots
  /// are what pushed the longest title into truncating on tight cards.
  fileprivate var bandPhaseTitle: String {
    var trimmed = phaseTitle
    while trimmed.hasSuffix("\u{2026}") || trimmed.hasSuffix(".") {
      trimmed.removeLast()
    }
    return trimmed.isEmpty ? phaseTitle : trimmed
  }

  /// One word of state for the watch band, where the full title has no room
  /// and a countdown-less "Next ping" reads as a question. Waiting phases say
  /// what just happened instead of promising a time.
  fileprivate var narrowStatusWord: String {
    switch phase {
    case "sending": return "Sending"
    case "discovering": return "Discovery"
    case "tracing": return "Tracing"
    case "listening", "listening_discovery", "listening_trace": return "Listening"
    case "waiting", "waiting_discovery", "waiting_trace", "cooldown": return "Sent"
    case "skipped": return "Skipped"
    case "waiting_for_gps": return "No GPS"
    case "paused_outside_zone": return "Paused"
    case "disconnected": return "Offline"
    case "tx_blocked": return "Blocked"
    case "stopping", "stopped": return "Stopped"
    case "starting": return "Starting"
    default: return bandPhaseTitle
    }
  }

  /// The app's own per-mode icon as an SF Symbol: swap arrows for Hybrid,
  /// a paperplane for Active's send, an ear for Passive, a scope for Trace.
  fileprivate var modeSymbol: String {
    switch mode.lowercased() {
    case "hybrid": return "arrow.left.arrow.right"
    case "passive": return "ear"
    case "trace", "targeted": return "scope"
    default: return "paperplane.fill"
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
      modeColor: .init(r: 0.30, g: 0.69, b: 0.31),
      isConnected: true,
      zoneCode: "SEA",
      noiseFloorDbm: -102,
      companionBatteryPct: 80,
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
      modeColor: .init(r: 0.30, g: 0.69, b: 0.31),
      isConnected: true,
      zoneCode: "SEA",
      noiseFloorDbm: -96,
      companionBatteryPct: 15,
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

  fileprivate static var previewGridMode: Self {
    var state = previewRunningWithResponses
    state.showRepeaterNames = false
    // The widest rows the grid can be handed: 6-character IDs from 3-byte
    // path mode with double-digit negative SNRs. The solver must fit these
    // on a 40 mm card without clipping.
    state.repeaters = state.repeaters.enumerated().map { index, repeater in
      MeshMapperActivityAttributes.HeardRepeater(
        id: repeater.id + String(format: "%02X", index),
        name: repeater.name,
        snr: index == 2 ? -12.4 : repeater.snr,
        typeColor: repeater.typeColor,
        snrColor: repeater.snrColor
      )
    }
    // Five and six, because the wide card's grid is two columns by three
    // rows and a four-entry sample cannot show the rank it must seat.
    state.repeaters += [
      .init(
        id: "C4D904",
        name: nil,
        snr: 4.2,
        typeColor: .init(r: 0.22, g: 0.80, b: 0.78),
        snrColor: .init(r: 0.34, g: 0.90, b: 0.44)
      ),
      .init(
        id: "77A005",
        name: nil,
        snr: -1.3,
        typeColor: .init(r: 0.64, g: 0.42, b: 0.94),
        snrColor: .init(r: 0.96, g: 0.76, b: 0.22)
      ),
    ]
    return state
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
      ("grid", .previewGridMode),
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
        // The wide layouts CarPlay renders; the exact CarPlay size is not
        // published and varies between drives, so these bracket both axes:
        // icon-only mode at 250 wide, the spelled-out mode word at 320, and
        // heights where the row solver must shrink (80) or the caps rule
        // (100).
        for width in [CGFloat(250), CGFloat(320)] {
          for height in [CGFloat(80), CGFloat(100)] {
            if let path = render(
              MeshMapperSmallActivityContent(state: state, isStale: false)
                .frame(width: width, height: height)
                .background(MeshMapperPalette.background),
              named: "small-carplay\(Int(width))x\(Int(height))-\(name)",
              in: directory
            ) {
              written.append(path)
            }
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

#Preview("Grid mode (names off)") {
  MeshMapperActivityPreview(state: .previewGridMode)
}
#endif
