import CoreLocation
import MapKit
import SwiftUI
import WatchKit

/// The map, drawn on Apple's basemap.
///
/// MeshMapper's own basemap cannot come along: `MKTileOverlay` is
/// `API_UNAVAILABLE(watchos)`, so the OpenFreeMap styles, the ArcGIS satellite
/// raster, and the coverage vector tiles have no route onto the wrist. Only
/// the data layer — ping colours, repeater pins, the fix — is MeshMapper's.
/// Apple's `.imagery` also renders pixel-identically to `.standard` here,
/// verified by pixel diff on device and simulator, so the watch exposes no
/// satellite mode.
struct MapPage: View {
  /// TabView may retain neighbouring pages. The selected tag is the reliable
  /// signal that this page is actually visible; view lifecycle alone cannot
  /// tell the phone whether its marker payload is useful.
  let isSelected: Bool

  @Environment(WatchSessionClient.self) private var client
  @Environment(WatchSettings.self) private var settings
  @Environment(\.isLuminanceReduced) private var environmentLuminanceReduced

  /// Always-On cannot be entered in the simulator, and on hardware it needs a
  /// wrist-down device — so the dimmed layout was unreviewable. This lets it be
  /// captured headlessly, like the sample-data affordances.
  private var isLuminanceReduced: Bool {
    #if DEBUG
    if UserDefaults.standard.bool(forKey: "MeshMapperForceDimmed") { return true }
    #endif
    return environmentLuminanceReduced
  }

  /// Content choice and display cadence are independent. A chosen readout can
  /// run at full luminance with a precise timer; reduced luminance selects the
  /// same approved surface because MapKit is not worth its Always-On cost.
  private var showsMap: Bool {
    settings.mainPageContent == .map && !isLuminanceReduced
  }

  private var needsMapGeo: Bool { showsMap && isSelected }

  @State private var camera: MapCameraPosition = .automatic

  /// Non-nil once we have driven the camera. Assignment is not proof that
  /// MapKit rendered the request, but it is the first half of the span
  /// handshake that keeps `.automatic` from becoming the remembered zoom.
  @State private var programmaticCenter: CLLocationCoordinate2D?

  /// Span counterpart to the centre handshake: MapKit can report its old
  /// `.automatic` fit after we assign a region, so assignment alone is not
  /// evidence that a rendered zoom came from us.
  @State private var hasConfirmedRequestedSpan = false

  /// Initial confirmation only needs to distinguish our request from the much
  /// wider automatic annotation fit. MapKit may adjust a requested region for
  /// display geometry, so a generous tolerance avoids quietly disabling Crown
  /// persistence by waiting forever for an exact span.
  private static let spanConfirmationTolerance = 0.25

  private var snapshot: WatchSnapshot? { client.snapshot }

  private var fix: CLLocationCoordinate2D? {
    guard let you = snapshot?.geo.you else { return nil }
    return CLLocationCoordinate2D(latitude: you.lat, longitude: you.lon)
  }

  private var isFollowing: Bool {
    settings.follow
  }

  @State private var showingNodes = false
  @State private var armedToolbarControl: TrailingToolbarControl?
  @State private var disarmToolbarTask: Task<Void, Never>?

  private enum TrailingToolbarControl: Equatable {
    case start
    case stop
    case ping

    var command: WatchCommand.Kind {
      switch self {
      case .start: return .startSession
      case .stop: return .stopSession
      case .ping: return .manualPing
      }
    }
  }

  /// The panel's frame in global coordinates, so the camera can keep the fix
  /// out from behind it.
  @State private var panelFrame: CGRect = .zero
  @State private var latchedTopSafeAreaInset: CGFloat = 0
  @State private var currentTopSafeAreaInset: CGFloat = 0
  @State private var bottomSafeAreaInset: CGFloat = 0

  /// Only one subtree sets this, but every *other* subtree still contributes
  /// the default. Taking `nextValue()` unconditionally would let a later
  /// sibling's `.zero` overwrite the real measurement, so empties are ignored.
  private struct PanelFrameKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
      let next = nextValue()
      if next != .zero { value = next }
    }
  }

  /// How much of the display the status panel is covering, handed to MapKit so
  /// it frames the camera in the band that remains visible.
  ///
  /// Measured rather than assumed: the panel's height changes with its content
  /// — one column or two, with or without heard rows — and a stale constant
  /// would drift the fix off centre exactly when the panel grew. Before the
  /// first measurement this is zero, which simply centres on the full display
  /// for a frame.
  private var panelCameraInset: CGFloat {
    guard panelFrame.height > 0 else { return 0 }
    return max(0, WKInterfaceDevice.current().screenBounds.height - panelFrame.minY)
  }

  /// The placement scales with the estimated corner radius, putting every
  /// watch at the same relative position on its curve. Ten points at R=19 is a
  /// modest lift from the hardware-approved eight; unlike the earlier
  /// deliberately narrow treatment, clearance is now evaluated at that real
  /// position so the lift buys the glanceable width the wearer requested.
  private static let panelBottomGapRatio: CGFloat = 10.0 / 19.0
  private static let readoutFailureBannerBottomGap: CGFloat = 3

  private var panelBottomGap: CGFloat {
    bottomSafeAreaInset * Self.panelBottomGapRatio
  }

  /// Panel geometry is about the physical display, not this view's proposal.
  /// Reading the device avoids a feedback loop where panel padding changes the
  /// container width that is then used to recompute that same padding.
  private var screenWidth: CGFloat { WKInterfaceDevice.current().screenBounds.width }

  /// Horizontal clearance that lets the panel descend into the bottom safe
  /// area without putting its corners outside the curved display.
  ///
  /// watchOS exposes no screen corner radius, but its bottom safe-area inset is
  /// the clearance a full-width element needs at zero horizontal inset, making
  /// it a useful estimate of that radius. The circle/chord intersection gives
  /// the inset at the panel's actual placement gap. That radius estimate is a
  /// lower bound on the glass curvature, so four extra points are cheap
  /// insurance against another hardware clip. The rectangle test is
  /// conservative in the other direction: the panel's own 12 pt radius pulls
  /// its visible corners inward from the square corners protected here.
  private var curvedPanelHorizontalInset: CGFloat? {
    let radius = bottomSafeAreaInset
    let gap = panelBottomGap
    guard radius > 0, gap < radius else { return nil }
    let inset = radius - sqrt(max(0, 2 * radius * gap - gap * gap)) + 4
    guard inset.isFinite else { return nil }
    return inset
  }

  /// A missing safe-area measurement is not permission to draw to the edge:
  /// retaining the old four-point inset and safe-area placement is the only
  /// fallback that is known not to clip on hardware.
  private var panelHorizontalInset: CGFloat { curvedPanelHorizontalInset ?? 4 }

  /// Width left after the curvature clearance and the panel's own 8 pt inset
  /// on each side. Row sizing uses this same budget as the rendered content,
  /// so its two-column decision does not depend on a nominal watch size.
  private var panelContentWidth: CGFloat {
    max(0, screenWidth - 2 * panelHorizontalInset - 16)
  }

  /// A centred toast with one radius of margin on each side is entirely
  /// inboard of the bottom curve, so its vertical position no longer needs the
  /// panel's chord calculation. Absence remains distinct from zero: without a
  /// measured radius the banner must stay in the safe area.
  private var readoutFailureBannerMaxWidth: CGFloat? {
    guard bottomSafeAreaInset > 0 else { return nil }
    let width = screenWidth - 2 * bottomSafeAreaInset
    guard width.isFinite, width > 0 else { return nil }
    return width
  }

  var body: some View {
    pageContent
      .toolbar {
        if !isLuminanceReduced {
          ToolbarItem(placement: .topBarLeading) {
            mainPageToggle
          }
          ToolbarItem(placement: .topBarTrailing) {
            trailingToolbarButton
          }
        }
      }
      .background(
        GeometryReader { geo in
          Color.clear
            .onAppear {
              noteTopSafeAreaInset(geo.safeAreaInsets.top)
              latchBottomSafeAreaInset(geo.safeAreaInsets.bottom)
            }
            .onChange(of: geo.safeAreaInsets.top) { _, inset in
              noteTopSafeAreaInset(inset)
            }
            .onChange(of: geo.safeAreaInsets.bottom) { _, inset in
              latchBottomSafeAreaInset(inset)
            }
            .onChange(of: isLuminanceReduced) { _, reduced in
              // If the view first appeared while dimmed, returning to full
              // luminance on the readout is the first valid opportunity to
              // establish the reference even when the inset did not change.
              if !reduced && !showsMap {
                noteTopSafeAreaInset(geo.safeAreaInsets.top)
              }
            }
            .onChange(of: showsMap) { _, mapIsShowing in
              // Switching from the map supplies a readout reference even if
              // both surfaces initially report the same transient inset.
              if !mapIsShowing && !isLuminanceReduced {
                noteTopSafeAreaInset(geo.safeAreaInsets.top)
              }
            }
        }
        // Plain is intentional: `.ignoresSafeArea()` makes this reader report
        // the insets of its own expanded region, which are zero. The bottom's
        // first nonzero value is latched before its dependent panel geometry can
        // feed back into layout; the top follows the separate visual-only rule
        // in `noteTopSafeAreaInset`.
      )
      .sheet(isPresented: $showingNodes) {
        NavigationStack {
          NodeListView()
            .navigationTitle("Heard")
            .navigationBarTitleDisplayMode(.inline)
        }
      }
      .onAppear {
        #if DEBUG
        // Lets the sheet layout be captured and iterated on headlessly; the
        // simulator has no way to tap the bar.
        if UserDefaults.standard.bool(forKey: "MeshMapperShowNodeSheet") {
          showingNodes = true
        }
        // A refusal normally needs a real command round-trip, which makes this
        // transient impossible to capture headlessly. It still expires through
        // the production six-second path, so screenshots must be prompt.
        if let forced = UserDefaults.standard.string(forKey: "MeshMapperForceRefusal") {
          client.debugForceRefusal(forced)
        }
        #endif
        client.setMapGeoNeeded(needsMapGeo)
      }
      .onChange(of: needsMapGeo) { _, needed in
        client.setMapGeoNeeded(needed)
      }
      .onChange(of: isSelected) { _, selected in
        // A sheet belongs to the page that raised it. Leaving one presented
        // while the pager moves on strands a modal over a different page,
        // where it blurs that page and swallows every swipe and Crown turn —
        // the app looks crashed while it is merely holding a stuck sheet.
        if !selected { showingNodes = false }
      }
      .onChange(of: trailingToolbarControl) { _, _ in
        // Stable facts own the slot, but a session transition still changes
        // its meaning. Never carry an armed confirmation into a new action.
        disarmToolbarControl()
      }
      .onChange(of: trailingToolbarControlIsEnabled) { _, enabled in
        if !enabled { disarmToolbarControl() }
      }
      .onChange(of: isLuminanceReduced) { _, reduced in
        if reduced { disarmToolbarControl() }
      }
      .onDisappear { disarmToolbarControl() }
  }

  private var pageContent: some View {
    ZStack {
      if showsMap {
        // Keep the reader inside this branch: constructing even map
        // infrastructure behind the readout would defeat its battery purpose.
        //
        // DECIDE BEFORE OPENING A PR: this reader is now vestigial. Camera
        // placement moved to safe-area insets, so nothing calls
        // `proxy.convert` and the proxy is threaded through five functions
        // unused. Removing it is a hierarchy change around a map whose launch
        // and framing behaviour was verified by measurement, so it wants its
        // own change and its own A/B — not a quiet tidy-up inside another one.
        MapReader { proxy in
          mapContent(proxy)
        }
      } else {
        readoutContent
      }
    }
  }

  private var commandFailure: String? {
    guard !isLuminanceReduced, let refusal = client.lastRefusal else {
      return nil
    }
    switch client.lastRefusalCommand {
    case nil, .startSession, .stopSession, .manualPing:
      return refusal
    case .requestSnapshot:
      return nil
    }
  }

  @ViewBuilder
  private var commandFailureBanner: some View {
    failureBanner(fillsAvailableWidth: true)
  }

  @ViewBuilder
  private var compactCommandFailureBanner: some View {
    failureBanner(fillsAvailableWidth: false)
  }

  @ViewBuilder
  private func failureBanner(fillsAvailableWidth: Bool) -> some View {
    if let commandFailure {
      HStack(alignment: .firstTextBaseline, spacing: 4) {
        Image(systemName: "exclamationmark.circle.fill")
        Text(commandFailure)
          .lineLimit(2)
      }
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(WatchPalette.armed)
      .multilineTextAlignment(.leading)
      .frame(
        maxWidth: fillsAvailableWidth ? .infinity : nil,
        alignment: .leading
      )
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
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
      // Placement belongs to each surface's overlay. The banner itself owns no
      // layout lifetime or geometry; the client still expires it after six
      // seconds, and reduced luminance suppresses it in `commandFailure`.
      .allowsHitTesting(false)
    }
  }

  private var mainPageToggle: some View {
    Button {
      settings.mainPageContent = settings.mainPageContent == .map
        ? .readout
        : .map
    } label: {
      // The glyph names the destination, following the convention for a
      // two-state corner control. The framed list survives toolbar scaling on
      // 40 mm better than bare bullets and still reads as the full readout.
      Image(systemName: settings.mainPageContent == .map
        ? "list.bullet.rectangle"
        : "map.fill")
    }
    .accessibilityLabel(settings.mainPageContent == .map
      ? "Show readout"
      : "Show map")
  }

  /// Slot identity follows stable session and regional facts, never the live
  /// ping gate. A cooldown may disable Ping, but cannot replace it with Stop
  /// while a finger is already moving toward the corner.
  private var trailingToolbarControl: TrailingToolbarControl {
    guard client.snapshot?.controls.isSessionActive == true else { return .start }
    if settings.showPingWhenAvailable,
       client.snapshot?.controls.manualPingApplicable == true
    {
      return .ping
    }
    return .stop
  }

  private var trailingToolbarControlIsEnabled: Bool {
    guard client.pendingCommand != trailingToolbarControl.command else { return false }
    switch trailingToolbarControl {
    case .start, .stop:
      return client.snapshot?.controls.canStartStop == true
    case .ping:
      return client.snapshot?.controls.canManualPing == true
    }
  }

  private var effectiveStartMode: WatchSettings.DefaultStartMode {
    settings.effectiveStartMode(
      availableStartModes: client.snapshot?.availableStartModes
    )
  }

  @ViewBuilder
  private var trailingToolbarButton: some View {
    let control = trailingToolbarControl
    let pending = client.pendingCommand == control.command
    let armed = armedToolbarControl == control

    let button = Button {
      handleToolbarControl(control)
    } label: {
      ZStack {
        if pending {
          ProgressView()
            .controlSize(.mini)
            .tint(toolbarActionColor(for: control))
        } else {
          Image(systemName: toolbarIcon(for: control, armed: armed))
            .foregroundStyle(toolbarGlyphColor(for: control, armed: armed))
        }
      }
      .frame(width: 18, height: 18)
    }
    .disabled(!trailingToolbarControlIsEnabled)
    .accessibilityLabel(toolbarAccessibilityLabel(for: control, armed: armed))

    if armed {
      // Resting actions use the same quiet glass container as the display
      // toggle. The three-second confirmation window is deliberately the only
      // filled state: its amber capsule signals that the next tap has a
      // consequence, rather than merely decorating a persistent control.
      button.tint(WatchPalette.armed)
    } else {
      button
    }
  }

  private func handleToolbarControl(_ control: TrailingToolbarControl) {
    switch control {
    case .start:
      disarmToolbarControl()
      client.send(.startSession, mode: effectiveStartMode.rawValue)
    case .stop, .ping:
      guard armedToolbarControl == control else {
        armToolbarControl(control)
        return
      }
      disarmToolbarControl()
      client.send(control.command)
    }
  }

  private func toolbarIcon(
    for control: TrailingToolbarControl,
    armed: Bool
  ) -> String {
    // With no usable connection, a dim play symbol falsely suggests that the
    // empty-looking glass control is a Start affordance. Name the unavailable
    // prerequisite instead; enablement remains entirely phone-owned.
    if snapshot?.isConnected != true {
      return "antenna.radiowaves.left.and.right.slash"
    }
    if armed { return "checkmark" }
    switch control {
    case .start: return "play.fill"
    case .stop: return "stop.fill"
    case .ping: return "dot.radiowaves.left.and.right"
    }
  }

  private func toolbarActionColor(
    for control: TrailingToolbarControl
  ) -> Color {
    switch control {
    case .start: return WatchPalette.start
    case .stop: return WatchPalette.stop
    case .ping: return WatchPalette.ping
    }
  }

  private func toolbarGlyphColor(
    for control: TrailingToolbarControl,
    armed: Bool
  ) -> Color {
    // The darker disabled slate vanished against Apple's darkest basemap.
    // System disabled dimming still distinguishes this brighter slate from an
    // enabled action without making the glass circle look empty.
    guard trailingToolbarControlIsEnabled else { return WatchPalette.tertiary }
    if armed { return .white }
    return toolbarActionColor(for: control)
  }

  private func toolbarAccessibilityLabel(
    for control: TrailingToolbarControl,
    armed: Bool
  ) -> String {
    guard let snapshot else { return "Waiting for iPhone" }
    guard snapshot.isConnected else { return "Device disconnected" }
    switch control {
    case .start: return "Start \(effectiveStartMode.label) session"
    case .stop: return armed ? "Confirm stop session" : "Stop session"
    case .ping: return armed ? "Confirm manual ping" : "Manual ping"
    }
  }

  private func armToolbarControl(_ control: TrailingToolbarControl) {
    disarmToolbarTask?.cancel()
    armedToolbarControl = control
    disarmToolbarTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(3))
      guard !Task.isCancelled, armedToolbarControl == control else { return }
      armedToolbarControl = nil
      disarmToolbarTask = nil
    }
  }

  private func disarmToolbarControl() {
    disarmToolbarTask?.cancel()
    disarmToolbarTask = nil
    armedToolbarControl = nil
  }

  private func mapContent(_ proxy: MapProxy) -> some View {
    ZStack {
      map(proxy)
      mapOverlay(proxy)
    }
    .onPreferenceChange(PanelFrameKey.self) { frame in
      guard abs(frame.minY - panelFrame.minY) > 0.5 || panelFrame.height == 0 else { return }
      panelFrame = frame
      recenterIfFollowing(proxy)
    }
    .onChange(of: snapshot?.geo.you.map { "\($0.lat),\($0.lon)" }) { _, _ in
      recenterIfFollowing(proxy)
    }
    .onAppear {
      recenterIfFollowing(proxy)
    }
  }

  private var readoutContent: some View {
    ZStack {
      // Always-On spends most of a long session with the wrist down, while a
      // wearer may also choose this as the full-luminance main page. In both
      // cases a black backing keeps the approved flat layout independent of
      // whatever container presents it.
      Color.black.ignoresSafeArea()
      readoutStatus
        // Hardware may collapse the navigation bar in Always-On even though
        // the simulator's force-dimmed path cannot. Restore only an inset that
        // disappeared relative to the full-luminance reference: equal insets
        // produce zero, while a missing measurement is deliberately a no-op.
        // Layout padding also consumes the height the collapsed bar returned,
        // keeping the flexible middle spacer identical to the reference. The
        // reader above receives its safe-area inset from the navigation host;
        // padding this descendant cannot alter that system-supplied value.
        .padding(.top, readoutTopOffset)
        // Anchor to this safe-area-respecting child, not `readoutContent`.
        // Its black sibling ignores the safe area and expands the enclosing
        // ZStack past the display bottom, which would place a bottom-aligned
        // banner off-screen — the same zero-inset trap this file has hit when
        // geometry was read from an expanded region.
        .overlay {
          if let maxWidth = readoutFailureBannerMaxWidth {
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              compactCommandFailureBanner
                // The transparent frame supplies a wrapping proposal and
                // centres the toast; its material background remains on the
                // intrinsic content rather than expanding permanent-looking
                // chrome to the cap.
                .frame(maxWidth: maxWidth)
            }
            // Three points keep the capsule's antialiasing visibly off the
            // physical edge. Curvature needs no further allowance once both
            // horizontal margins are at least the measured radius.
            .padding(.bottom, Self.readoutFailureBannerBottomGap)
            .ignoresSafeArea(edges: .bottom)
          } else {
            VStack(spacing: 0) {
              Spacer(minLength: 0)
              commandFailureBanner
            }
            // No measured radius means no permission to enter the bottom safe
            // area; preserve the last known-safe placement exactly.
            .padding(.horizontal, panelHorizontalInset)
            .padding(.bottom, 4)
          }
        }
    }
  }

  private var readoutTopOffset: CGFloat {
    guard latchedTopSafeAreaInset > 0 else { return 0 }
    return max(0, latchedTopSafeAreaInset - currentTopSafeAreaInset)
  }

  /// Map chrome remains an overlay so its measured frame can place the fix in
  /// the visible band above it. The readout has its own hierarchy and therefore
  /// cannot accidentally inherit this bottom-pinned card again.
  private func mapOverlay(_ proxy: MapProxy) -> some View {
    VStack(spacing: 0) {
      HStack {
        Spacer(minLength: 0)
        recenterButton(proxy)
      }
      Spacer(minLength: 0)
      statusPanel
        .overlay(alignment: .top) {
          commandFailureBanner
            .padding(.horizontal, 4)
            // Aligning a guide below the banner with the panel's top puts the
            // transient immediately above the measured card. Unlike adding a
            // VStack row, an overlay contributes no size, so neither the
            // panel's signed-off placement nor PanelFrameKey can move.
            .alignmentGuide(.top) { dimensions in
              dimensions[.bottom] + 3
            }
        }
        .background(
          GeometryReader { geo in
            Color.clear.preference(key: PanelFrameKey.self, value: geo.frame(in: .global))
          }
        )
    }
    // Earlier full-width versions clipped on curved hardware even though the
    // simulator looked sound. Enter the bottom safe area only after the circle
    // model has bought the matching horizontal clearance.
    .padding(.horizontal, panelHorizontalInset)
    .padding(.top, 2)
    .padding(.bottom, curvedPanelHorizontalInset == nil ? 0 : panelBottomGap)
    .ignoresSafeArea(edges: curvedPanelHorizontalInset == nil ? [] : .bottom)
  }

  /// A full-screen glance surface, not a map card without a map.
  ///
  /// Its content remains inside the system safe area and also keeps the
  /// hardware-tested horizontal clearance. That is intentionally redundant at
  /// the bottom corners: two earlier layouts passed in the simulator and
  /// clipped on glass, while spare black pixels cost no compositing work.
  private var readoutStatus: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let snapshot {
        ReadoutPhase(snapshot: snapshot, isLuminanceReduced: isLuminanceReduced)
      } else {
        Text("Waiting for iPhone")
          .font(.system(size: 17, weight: .bold))
          .foregroundStyle(.white.opacity(0.55))
          .lineLimit(1)
      }

      Spacer(minLength: 6)

      VStack(alignment: .leading, spacing: 3) {
        Text("TOP HEARD")
          .font(.system(size: 10, weight: .semibold))
          .foregroundStyle(.white.opacity(0.55))

        if heard.isEmpty {
          Text("Nothing heard")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          ForEach(Array(heard.prefix(4))) { node in
            readoutHeardRow(node)
          }
        }
      }
    }
    .padding(.horizontal, panelHorizontalInset)
    .padding(.vertical, 4)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .dynamicTypeSize(.small ... .large)
    .opacity(client.isStale ? 0.5 : 1.0)
    // Snapshot replacement may arrive with an animated transaction from an
    // ancestor. Readout state changes are discrete; only the native precise
    // countdown updates between them at full luminance.
    .transaction { $0.animation = nil }
  }

  /// One full-width row is affordable without a basemap and gives the settled
  /// type dot, hex identity and quality figure enough size for arm's-length
  /// reading even when a six-character hash forces the overlay into one column.
  private func readoutHeardRow(_ node: WatchHeardNode) -> some View {
    HStack(spacing: 5) {
      Circle()
        .fill(Color(node.typeColor))
        .frame(width: 8, height: 8)
      Text(node.id)
        .font(.system(size: 13, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
      Spacer(minLength: 6)
      if let snr = node.snr {
        Text(snr, format: .number.precision(.fractionLength(1)))
          .font(.system(size: 13, weight: .semibold, design: .monospaced))
          .foregroundStyle(node.snrColor.map(Color.init) ?? .white)
          .frame(width: 42, alignment: .trailing)
      }
    }
    .lineLimit(1)
  }

  private func latchBottomSafeAreaInset(_ inset: CGFloat) {
    guard bottomSafeAreaInset == 0, inset > 0 else { return }
    bottomSafeAreaInset = inset
  }

  private func noteTopSafeAreaInset(_ inset: CGFloat) {
    guard inset.isFinite else { return }
    currentTopSafeAreaInset = max(0, inset)

    // Only the full-luminance readout is the approved reference; the map extends
    // beneath top chrome and reports a different inset. Keep its largest value
    // because the navigation bar settles upward after installing its toolbar.
    // This intentionally differs from the bottom inset's first-nonzero latch:
    // the bottom value drives padding and can feed back into its measurement,
    // while the top value comes from the parent navigation host and drives
    // padding only inside its readout child, which cannot change that inset.
    guard !isLuminanceReduced, !showsMap, inset > 0 else { return }
    latchedTopSafeAreaInset = max(latchedTopSafeAreaInset, inset)
  }

  /// Phase and Top Heard in one panel.
  ///
  /// Rows are `[type dot] [hex ID] [SNR]`. The hex path hash is the identity,
  /// because a 1-byte hash frequently cannot be resolved to a single repeater;
  /// a name is appended only when the phone could resolve it unambiguously.
  private var statusPanel: some View {
    Button {
      // Only a sheet placement has anything to open. With the list on its own
      // page this was presenting a duplicate of a page that already exists —
      // and because the panel sits across the bottom of the map, where an
      // upward page swipe begins, it fired on swipes the wearer meant for the
      // pager and stranded a modal over the next page.
      guard settings.nodeListPlacement == .sheet else { return }
      showingNodes = true
    } label: {
      VStack(alignment: .leading, spacing: 3) {
        timerBar

        if heard.isEmpty {
          Text("Nothing heard")
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.45))
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
          // Two columns are the useful glance layout even on 40 mm, so type
          // shrinks against the same width model as the actual row. Only a
          // six-character zone that would cross the 7 pt legibility floor gets
          // one column; truncating the ID is not an option because it is the
          // repeater's identity.
          if twoHeardColumnsFit {
            HStack(alignment: .top, spacing: columnGap) {
              heardColumn(Array(heard.prefix(2)))
              heardColumn(Array(heard.dropFirst(2)))
            }
          } else {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(heard) { heardRow($0) }
            }
          }
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Bright basemap labels bleed through flat translucency and fight the
      // SNR digits; material removes that competing detail on the map only.
      .background(.ultraThinMaterial, in: .rect(cornerRadius: 12, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
      )
    }
    .buttonStyle(.plain)
    // A HUD, not body copy: fixed sizes keep it from swallowing the map at
    // large accessibility text sizes. The scrollable detail list is where the
    // wearer's text-size setting is honoured.
    .dynamicTypeSize(.small ... .large)
    .opacity(client.isStale ? 0.5 : 1.0)
  }

  /// A stable gutter keeps the width equation and the rendered columns in
  /// agreement; changing it by device size would silently spend the room the
  /// font calculation just recovered on the smallest watch.
  private var columnGap: CGFloat { 8 }

  /// One column of heard rows.
  private func heardColumn(_ nodes: [WatchHeardNode]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(nodes) { heardRow($0) }
    }
  }

  /// `[type dot] [hex ID] [SNR]`, sized to its content.
  ///
  /// Content-sized on purpose so the row's intrinsic measurement stays equal
  /// to the width model that chooses the font and column count.
  private func heardRow(_ node: WatchHeardNode) -> some View {
    HStack(spacing: 3) {
      Circle()
        .fill(Color(node.typeColor))
        .frame(width: 6, height: 6)
      Text(node.id)
        .font(.system(size: rowFontSize, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white)
      if let snr = node.snr {
        Text(snr, format: .number.precision(.fractionLength(1)))
          .font(.system(size: rowFontSize, weight: .semibold, design: .monospaced))
          .foregroundStyle(node.snrColor.map(Color.init) ?? .white)
          // Fixed width so SNRs line up down a column despite varying digits.
          .frame(width: rowFontSize * 3.1, alignment: .trailing)
      }
    }
    .lineLimit(1)
    .fixedSize()
  }

  /// The phase as a depleting bar with its remaining time.
  ///
  /// The bar drains right to left from `phaseEndsAt` and `phaseDurationMs`,
  /// both absolute, so it is correct without per-second updates and correct
  /// when the app opens midway through a phase. A stale payload replaces the
  /// whole row: a bar that keeps draining against a deadline the phone has
  /// stopped confirming is worse than no bar.
  @ViewBuilder
  private var timerBar: some View {
    if client.isStale, let receivedAt = client.receivedAt {
      HStack(spacing: 3) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 8))
        Text(receivedAt, style: .relative)
          .font(.system(size: 10, weight: .medium))
        Text("old")
          .font(.system(size: 10))
        Spacer(minLength: 0)
      }
      .foregroundStyle(.orange)
      .lineLimit(1)
    } else if let snapshot {
      WatchPhaseBar(snapshot: snapshot)
      .frame(height: 15)
    }
  }

  /// Largest size allowed by the hash-length ladder. The watch now permits one
  /// point more than the phone-derived sizes: it is read at arm's length in
  /// motion, and the width solver still prevents that legibility gain from
  /// making an intrinsic row overflow its column.
  private var rowFontSizeCap: CGFloat {
    let widest = heard.map(\.id.count).max() ?? 2
    if widest > 4 { return 10 }
    if widest > 2 { return 11 }
    return 12
  }

  /// Font size that leaves two intrinsic rows safely inside their columns.
  /// The constants mirror `heardRow`: dot and gaps consume 12 pt, semibold
  /// monospaced IDs advance closer to 0.62 em than the nominal 0.6, and the
  /// aligned SNR owns 3.1 em. Two points of slack make measurement error land
  /// on smaller type rather than a wider panel that defeats its edge clearance.
  private var unconstrainedRowFontSize: CGFloat {
    let idChars = CGFloat(heard.map(\.id.count).max() ?? 2)
    let columnWidth = (panelContentWidth - columnGap) / 2 - 2
    return (columnWidth - 12) / (0.62 * idChars + 3.1)
  }

  /// Eight points is the new glanceability floor for two columns. Without it,
  /// the extra width makes six-character IDs on 40 mm barely “fit” at about
  /// seven points and regress from the clearer single-column treatment.
  private var twoHeardColumnsFit: Bool { unconstrainedRowFontSize >= 8 }

  private var rowFontSize: CGFloat {
    guard twoHeardColumnsFit else { return rowFontSizeCap }
    return min(unconstrainedRowFontSize.clamped(to: 8...12), rowFontSizeCap)
  }

  private var heard: [WatchHeardNode] { snapshot?.geo.heard ?? [] }

  @ViewBuilder
  private func recenterButton(_ proxy: MapProxy) -> some View {
    if !isFollowing, fix != nil {
      Button {
        recenterIfFollowing(proxy, force: true)
      } label: {
        Image(systemName: "location.fill")
          .font(.system(size: 10))
      }
      .buttonStyle(.borderless)
      .padding(4)
      .background(.black.opacity(0.5), in: Circle())
    }
  }

  // MARK: - Map

  private func map(_ proxy: MapProxy) -> some View {
    // Pan consumes the vertical gesture the page shell needs, while the Crown
    // remains the deliberate zoom control. Once drag input is absent, centre
    // drift cannot honestly identify a pan — MapKit and Crown zoom can both
    // produce it — so follow has no distance-based suspension path to misfire.
    Map(position: $camera, interactionModes: [.zoom]) {
      linkLines
      pingMarkers
      repeaterPins
      fixMarker
    }
    .mapStyle(.standard)
    // Tell MapKit what is covering the map, rather than hand-shifting the
    // camera to compensate. Its own centre then *is* the centre of the band
    // the wearer can actually see, so the fix lands there without a correction
    // pass and a Crown zoom anchors on it instead of sliding it across.
    //
    // Both edges matter. Insetting only the bottom centres the fix in
    // `0...panelTop`, which still includes the toolbar strip, and the puck then
    // reads high — obviously so on 46 mm, where the chrome is a smaller
    // fraction of the display.
    .safeAreaPadding(.top, currentTopSafeAreaInset)
    .safeAreaPadding(.bottom, panelCameraInset)
    .onMapCameraChange(frequency: .onEnd) { context in
      noteRenderedRegion(context.region)
    }
    // The shell's navigation host supplies the system toolbar placement but
    // must not buy it by shortening the basemap. Only MapKit extends under that
    // top chrome; the overlay remains in the safe content region, keeping its
    // inset recentre button below the system toolbar controls.
    .ignoresSafeArea(edges: [.top, .bottom])
  }

  @MapContentBuilder
  private var linkLines: some MapContent {
    if settings.showLinks, let fix, let snapshot {
      ForEach(linkedRepeaters(in: snapshot.geo)) { repeater in
        MapPolyline(coordinates: [
          fix,
          CLLocationCoordinate2D(latitude: repeater.lat, longitude: repeater.lon),
        ])
        .stroke(Color(repeater.color).opacity(0.7), lineWidth: 1.5)
      }
    }
  }

  /// Heard identities are path-hash prefixes, not API database IDs. Resolve
  /// against the full hex carried by each pin, and require one match per
  /// prefix: a line asserts a real radio path, so an ambiguous line is worse
  /// than drawing none. The phone performs the same check against the full
  /// catalogue before sending; repeating it here keeps malformed or older
  /// payloads from turning ambiguity into a visual claim.
  private func linkedRepeaters(in geo: WatchGeo) -> [WatchRepeater] {
    var resolved = [WatchRepeater]()
    var seen = Set<String>()

    for rawPrefix in geo.linkedRepeaterIds {
      let prefix = rawPrefix.uppercased()
      guard !prefix.isEmpty else { continue }
      let matches = geo.repeaters.filter {
        $0.hexId?.uppercased().hasPrefix(prefix) == true
      }
      guard matches.count == 1, seen.insert(matches[0].id).inserted else { continue }
      resolved.append(matches[0])
    }
    return resolved
  }

  @MapContentBuilder
  private var pingMarkers: some MapContent {
    if let snapshot {
      ForEach(snapshot.geo.pings) { ping in
        Annotation("", coordinate: CLLocationCoordinate2D(latitude: ping.lat, longitude: ping.lon)) {
          // The phone's marker style is a user preference the watch does not
          // receive, so mirror its default dot: a filled circle with a soft
          // white border. The phone's shadow is omitted at this wrist scale.
          Circle()
            .fill(Color(ping.color))
            .frame(width: 6, height: 6)
            .overlay(
              Circle()
                .strokeBorder(.white.opacity(0.6), lineWidth: 0.75)
            )
        }
        .annotationTitles(.hidden)
      }
    }
  }

  @MapContentBuilder
  private var repeaterPins: some MapContent {
    if let snapshot {
      ForEach(snapshot.geo.repeaters) { repeater in
        Annotation("", coordinate: CLLocationCoordinate2D(latitude: repeater.lat, longitude: repeater.lon)) {
          RepeaterPin(color: Color(repeater.color), highlighted: repeater.heardThisCycle)
        }
        .annotationTitles(.hidden)
      }
    }
  }

  @MapContentBuilder
  private var fixMarker: some MapContent {
    if let fix, let you = snapshot?.geo.you {
      Annotation("", coordinate: fix) {
        // The phone's fix, not the watch's. Rendering it ourselves keeps the
        // watch free of any location permission.
        FixPuck(headingDeg: you.headingDeg)
      }
      .annotationTitles(.hidden)
    }
  }

  // MARK: - Camera

  private func recenterIfFollowing(_ proxy: MapProxy, force: Bool = false) {
    guard showsMap, force || isFollowing, let fix else { return }
    // Centre on the fix itself. The camera inset already accounts for the
    // panel, so no compensating shift is needed and nothing has to be
    // corrected after the map reports back.
    programmaticCenter = fix
    let region = MKCoordinateRegion(center: fix, span: currentSpan)

    if force {
      // A tap is a rare, explicit request to move the map, so animation shows
      // the wearer what their action changed. Automatic follow is different:
      // the fix coordinate has already changed in this frame, and animating
      // the camera after it makes the puck wander before the map catches up.
      withAnimation(.easeInOut(duration: 0.25)) {
        camera = .region(region)
      }
    } else {
      // First placement and GPS steps cut, so the puck stays visually fixed
      // while the world moves beneath it.
      camera = .region(region)
    }
  }

  /// MapKit fits longitude to the watch's aspect ratio, so latitude is the one
  /// independent zoom value. After the one-time defaults migration it starts
  /// at 0.00225 degrees, about 250 m north-south, and later launches reuse the
  /// wearer's Crown setting.
  private var currentSpan: MKCoordinateSpan {
    MKCoordinateSpan(
      latitudeDelta: settings.mapLatitudeDelta,
      longitudeDelta: settings.mapLatitudeDelta
    )
  }

  /// Track the region MapKit actually rendered, so a Digital Crown zoom is not
  /// thrown away on the next follow update.
  private func noteRenderedRegion(_ region: MKCoordinateRegion) {
    // `.automatic` can report its annotation fit even after we assign our first
    // region, so `programmaticCenter != nil` proves only that a request was
    // made, not that MapKit rendered it. Persist nothing until the rendered
    // span confirms the request; later deviations are Crown zooms and remain
    // eligible for the normal write-back below.
    guard programmaticCenter != nil else { return }

    let rendered = region.span.latitudeDelta
    let requested = settings.mapLatitudeDelta
    guard rendered.isFinite, requested.isFinite, requested > 0 else { return }

    guard hasConfirmedRequestedSpan else {
      let relativeDifference = abs(rendered - requested) / requested
      if relativeDifference <= Self.spanConfirmationTolerance {
        hasConfirmedRequestedSpan = true
      }
      return
    }

    // Only on a real change. Every follow update produces a camera change, and
    // writing an identical value would persist and invalidate on each one,
    // re-rendering the map for nothing.
    guard abs(rendered - requested) / requested > 0.01 else { return }
    settings.mapLatitudeDelta = rendered
  }

}

/// A phase-scoped progress animation rather than a one-second render clock.
///
/// `Text(timerInterval:)` owns its countdown without invalidating this view.
/// The fill is set once from the absolute deadline and animated to zero by the
/// compositor; one sleeping task wakes at the deadline solely to retire the
/// countdown and dim a claim the phone has not refreshed.
private struct WatchPhaseBar: View {
  let snapshot: WatchSnapshot

  @State private var remainingFraction: CGFloat
  @State private var deadlineLapsed: Bool

  init(snapshot: WatchSnapshot) {
    self.snapshot = snapshot
    let now = Date()
    _remainingFraction = State(
      initialValue: CGFloat(snapshot.phaseRemainingFraction(at: now) ?? 0)
    )
    _deadlineLapsed = State(
      initialValue: snapshot.phaseEndsAt.map { $0 <= now } ?? false
    )
  }

  private var phaseKey: PhaseAnimationKey {
    PhaseAnimationKey(
      endsAtMs: snapshot.phaseEndsAtMs,
      durationMs: snapshot.phaseDurationMs
    )
  }

  /// Build the native timer's range at render time so a deadline crossing
  /// between the sleeping task and a body update can never form `now...past`.
  private var activeCountdownRange: ClosedRange<Date>? {
    let now = Date()
    guard !deadlineLapsed, let endsAt = snapshot.phaseEndsAt, endsAt > now else {
      return nil
    }
    return now...endsAt
  }

  var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.16))
        Capsule()
          .fill(snapshot.pingColor.map(Color.init) ?? .accentColor)
          .frame(width: geo.size.width * remainingFraction)
      }
      .overlay {
        HStack {
          // A missing deadline describes a durable state. A passed one is only
          // the phone's last claim, so keep it visible but no longer assert it.
          Text(snapshot.phaseTitle)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.white.opacity(deadlineLapsed ? 0.45 : 1))
            .lineLimit(1)
            .truncationMode(.tail)
          Spacer(minLength: 4)
          if let range = activeCountdownRange {
            // Fixed width because the native timer otherwise reserves room for
            // its widest possible value and starves the title.
            Text(timerInterval: range, countsDown: true)
              .font(.system(size: 11, weight: .bold).monospacedDigit())
              .foregroundStyle(.white)
              .frame(width: 38, alignment: .trailing)
          }
        }
        // The fill slides under both labels, so a shadow keeps them readable
        // against the filled and empty parts of the track.
        .shadow(color: .black.opacity(0.7), radius: 1.5)
        .padding(.horizontal, 6)
      }
    }
    .task(id: phaseKey) {
      await runPhaseAnimation()
    }
  }

  @MainActor
  private func runPhaseAnimation() async {
    let now = Date()
    let fraction = CGFloat(snapshot.phaseRemainingFraction(at: now) ?? 0)
    let lapsed = snapshot.phaseEndsAt.map { $0 <= now } ?? false

    // A replacement phase must start at its true current fraction, not animate
    // from the previous phase's endpoint before beginning its own drain.
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      remainingFraction = fraction
      deadlineLapsed = lapsed
    }

    guard let endsAt = snapshot.phaseEndsAt else { return }
    let remaining = endsAt.timeIntervalSince(now)
    guard remaining > 0 else { return }

    await Task.yield()
    #if DEBUG
    // A/B harness for the drain's energy cost. The fill is an animated *layout*
    // width, so SwiftUI re-runs layout every frame for the whole phase rather
    // than handing a transform to the render server. Freezing it leaves every
    // other cost in place — same snapshots, same markers, same timer text — so
    // an Instruments trace of the two states isolates this animation alone.
    if !WatchSettings.debugFreezesTimerBar {
      withAnimation(.linear(duration: remaining)) { remainingFraction = 0 }
    }
    #else
    withAnimation(.linear(duration: remaining)) {
      remainingFraction = 0
    }
    #endif

    do {
      try await Task.sleep(for: .seconds(remaining))
    } catch {
      return
    }
    guard !Task.isCancelled else { return }
    deadlineLapsed = true
  }

  private struct PhaseAnimationKey: Hashable {
    // The drain depicts time, not its caption. Skip mode can change the title
    // against the same timer; including it here would cancel, snap and restart
    // an otherwise continuous bar every time the label flips.
    let endsAtMs: Double?
    let durationMs: Int?
  }
}

extension Comparable {
  fileprivate func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}

/// The approved full-screen phase treatment with cadence chosen independently
/// from its layout. Always-On updates too slowly to promise seconds, while a
/// wearer-selected readout at full luminance can let the native timer provide
/// a precise countdown without a one-second SwiftUI timeline.
private struct ReadoutPhase: View {
  let snapshot: WatchSnapshot
  let isLuminanceReduced: Bool

  @State private var deadlineLapsed: Bool

  init(snapshot: WatchSnapshot, isLuminanceReduced: Bool) {
    self.snapshot = snapshot
    self.isLuminanceReduced = isLuminanceReduced
    _deadlineLapsed = State(
      initialValue: snapshot.phaseEndsAt.map { $0 <= Date() } ?? false
    )
  }

  private var phaseKey: PhaseKey {
    PhaseKey(
      endsAtMs: snapshot.phaseEndsAtMs,
      isLuminanceReduced: isLuminanceReduced
    )
  }

  var body: some View {
    Group {
      if isLuminanceReduced {
        // A seconds figure can be nearly a minute wrong while watchOS throttles
        // Always-On. Match that cadence explicitly instead of showing false
        // precision, and isolate the minute wake-up to this small subtree.
        TimelineView(.periodic(from: .now, by: 60)) { context in
          phase(at: context.date, usesCoarseCountdown: true)
        }
      } else {
        phase(at: Date(), usesCoarseCountdown: false)
      }
    }
    .task(id: phaseKey) {
      await trackDeadline()
    }
  }

  @ViewBuilder
  private func phase(at date: Date, usesCoarseCountdown: Bool) -> some View {
    let lapsed = usesCoarseCountdown
      ? snapshot.phaseEndsAt.map { $0 <= date } ?? false
      : deadlineLapsed

    VStack(alignment: .leading, spacing: 2) {
      // Wrapping is intentional. The longest real phase names need two lines
      // on 40 mm, and preserving every word matters more than uniform height.
      Text(snapshot.phaseTitle)
        .font(.system(size: 18, weight: .bold))
        .foregroundStyle(.white.opacity(lapsed ? 0.45 : 1))
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

      if usesCoarseCountdown {
        if let countdown = coarseCountdown(at: date) {
          countdownText(countdown)
        }
      } else if !lapsed, let endsAt = snapshot.phaseEndsAt, endsAt > date {
        Text(timerInterval: date...endsAt, countsDown: true)
          .font(.system(size: 24, weight: .bold).monospacedDigit())
          .foregroundStyle(.white)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func countdownText(_ value: String) -> some View {
    Text(value)
      .font(.system(size: 24, weight: .bold).monospacedDigit())
      .foregroundStyle(.white)
      .fixedSize(horizontal: false, vertical: true)
      .frame(maxWidth: .infinity, alignment: .leading)
  }

  private func coarseCountdown(at date: Date) -> String? {
    guard let endsAt = snapshot.phaseEndsAt else { return nil }
    let remaining = endsAt.timeIntervalSince(date)
    guard remaining > 0 else { return nil }
    // These are upper bounds, not estimates. Remaining time only decreases,
    // so a tight statement rendered just before Always-On stops refreshing
    // stays true afterward. Resolve it from this phase's live deadline on each
    // render; retaining a previous phase's bound could make that guarantee
    // false when a new, longer countdown begins.
    if remaining < 15 { return "<15 sec" }
    if remaining < 30 { return "<30 sec" }
    if remaining < 60 { return "<1 min" }
    return "\(Int(ceil(remaining / 60))) min"
  }

  @MainActor
  private func trackDeadline() async {
    let now = Date()
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      deadlineLapsed = snapshot.phaseEndsAt.map { $0 <= now } ?? false
    }

    // The minute timeline owns this boundary under Always-On. Sleeping for an
    // exact second there would imply precision the display cannot present.
    guard !isLuminanceReduced, let endsAt = snapshot.phaseEndsAt else { return }
    let remaining = endsAt.timeIntervalSince(now)
    guard remaining > 0 else { return }
    do {
      try await Task.sleep(for: .seconds(remaining))
    } catch {
      return
    }
    guard !Task.isCancelled else { return }
    deadlineLapsed = true
  }

  private struct PhaseKey: Hashable {
    let endsAtMs: Double?
    let isLuminanceReduced: Bool
  }
}

// MARK: - Markers

private struct FixPuck: View {
  let headingDeg: Double?

  var body: some View {
    ZStack {
      Circle()
        .fill(.blue)
        .frame(width: 10, height: 10)
      Circle()
        .stroke(.white, lineWidth: 1.5)
        .frame(width: 10, height: 10)
      if let headingDeg {
        Image(systemName: "location.north.fill")
          .font(.system(size: 7))
          .foregroundStyle(.white)
          .offset(y: -9)
          .rotationEffect(.degrees(headingDeg))
      }
    }
  }
}

private struct RepeaterPin: View {
  let color: Color
  let highlighted: Bool

  var body: some View {
    ZStack {
      if highlighted {
        Circle()
          .stroke(color, lineWidth: 1.5)
          .frame(width: 14, height: 14)
      }
      Circle()
        .fill(color)
        .frame(width: 7, height: 7)
        .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 0.5))
    }
  }
}
