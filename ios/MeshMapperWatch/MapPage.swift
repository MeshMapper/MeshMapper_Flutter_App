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
struct MapPage: View {
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

  @State private var camera: MapCameraPosition = .automatic

  /// Centre we last drove the camera to, so a camera change can be attributed
  /// to the wearer rather than to our own follow updates.
  @State private var programmaticCenter: CLLocationCoordinate2D?
  @State private var followSuspendedUntil: Date?

  /// Whether MapKit has ever reported back a centre we asked for. Until it has,
  /// a disagreeing centre is `.automatic` settling, not the wearer — see
  /// `noteCameraChange`.
  @State private var hasConfirmedRequestedCenter = false

  /// Metres of disagreement before a camera change counts as a real pan.
  private static let panTolerance: CLLocationDistance = 40

  /// How long a pan pauses following before the map drifts back to the fix.
  private static let resumeFollowAfter: TimeInterval = 8

  private var snapshot: WatchSnapshot? { client.snapshot }

  private var fix: CLLocationCoordinate2D? {
    guard let you = snapshot?.geo.you else { return nil }
    return CLLocationCoordinate2D(latitude: you.lat, longitude: you.lon)
  }

  private var isFollowing: Bool {
    guard settings.follow else { return false }
    if let until = followSuspendedUntil, until > Date() { return false }
    return true
  }

  @State private var showingNodes = false

  /// The panel's frame in global coordinates, so the camera can keep the fix
  /// out from behind it.
  @State private var panelFrame: CGRect = .zero
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

  /// Where the fix belongs on screen: midway between the top of the display and
  /// the top of the panel.
  private var targetPoint: CGPoint? {
    guard panelFrame.height > 0 else { return nil }
    return CGPoint(x: panelFrame.midX, y: panelFrame.minY / 2)
  }

  /// The placement scales with the estimated corner radius, putting every
  /// watch at the same relative position on its curve. Ten points at R=19 is a
  /// modest lift from the hardware-approved eight; unlike the earlier
  /// deliberately narrow treatment, clearance is now evaluated at that real
  /// position so the lift buys the glanceable width the wearer requested.
  private static let panelBottomGapRatio: CGFloat = 10.0 / 19.0

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

  var body: some View {
    // The proxy is the only reliable way to relate a coordinate to a point on
    // screen. The map draws outside its own layout frame — it ignores the
    // bottom safe area, and on a 46 mm watch the frame SwiftUI reports is
    // 159 pt tall against a 248 pt display — so no measurement of the view
    // hierarchy predicts where a coordinate will actually land. Asking the map
    // sidesteps the whole question.
    MapReader { proxy in
      content(proxy)
    }
  }

  private func content(_ proxy: MapProxy) -> some View {
    ZStack {
      if isLuminanceReduced {
        // Always-On spends most of a long session with the wrist down. A live
        // MapKit renderer and its annotations buy no useful glance information
        // at reduced luminance, so remove that subtree rather than merely
        // covering it.
        Color.black.ignoresSafeArea()
        dimmedStatus
      } else {
        map(proxy)
        mapOverlay(proxy)
      }
    }
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { latchBottomSafeAreaInset(geo.safeAreaInsets.bottom) }
          .onChange(of: geo.safeAreaInsets.bottom) { _, inset in
            latchBottomSafeAreaInset(inset)
          }
      }
      // Plain is intentional: `.ignoresSafeArea()` makes this reader report
      // the insets of its own expanded region, which are zero. The first
      // nonzero value is latched while the panel is still in its safe fallback
      // placement; later panel geometry depends on it, while the display's
      // actual safe area is a device constant that cannot legitimately change.
    )
    .onPreferenceChange(PanelFrameKey.self) { frame in
      guard abs(frame.minY - panelFrame.minY) > 0.5 || panelFrame.height == 0 else { return }
      panelFrame = frame
      recenterIfFollowing(proxy)
    }
    .sheet(isPresented: $showingNodes) {
      NavigationStack {
        NodeListView()
          .navigationTitle("Heard")
          .navigationBarTitleDisplayMode(.inline)
      }
    }
    .onChange(of: snapshot?.geo.you.map { "\($0.lat),\($0.lon)" }) { _, _ in
      recenterIfFollowing(proxy)
    }
    // The delayed resume in `scheduleFollowResume` only clears the suspension;
    // recentring happens here, where a live proxy is in scope.
    .onChange(of: followSuspendedUntil) { _, until in
      if until == nil { recenterIfFollowing(proxy) }
    }
    .onChange(of: isLuminanceReduced) { _, reduced in
      // Camera work is forbidden while dimmed. Returning to full luminance is
      // itself a state change, so following can resume immediately even if the
      // phone has not produced another GPS fix yet.
      if !reduced { recenterIfFollowing(proxy) }
    }
    .onAppear {
      recenterIfFollowing(proxy)
      #if DEBUG
      // Lets the sheet layout be captured and iterated on headlessly; the
      // simulator has no way to tap the bar.
      if UserDefaults.standard.bool(forKey: "MeshMapperShowNodeSheet") {
        showingNodes = true
      }
      #endif
    }
  }

  /// Map chrome remains an overlay so its measured frame can place the fix in
  /// the visible band above it. Always-On has its own hierarchy and therefore
  /// cannot accidentally inherit this bottom-pinned card again.
  private func mapOverlay(_ proxy: MapProxy) -> some View {
    VStack(spacing: 0) {
      HStack {
        Spacer(minLength: 0)
        recenterButton(proxy)
      }
      Spacer(minLength: 0)
      statusPanel
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

  /// A full-screen glance surface for Always-On, not a map card without a map.
  ///
  /// Its content remains inside the system safe area and also keeps the
  /// hardware-tested horizontal clearance. That is intentionally redundant at
  /// the bottom corners: two earlier layouts passed in the simulator and
  /// clipped on glass, while spare black pixels cost no compositing work.
  private var dimmedStatus: some View {
    VStack(alignment: .leading, spacing: 0) {
      if let snapshot {
        dimmedPhase(snapshot)
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
            dimmedHeardRow(node)
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
    // ancestor. Always-On changes in discrete steps; it never interpolates.
    .transaction { $0.animation = nil }
  }

  /// The two readings an Always-On glance exists to answer, each with its own
  /// line instead of competing inside the map overlay's narrow bar.
  ///
  /// A seconds figure can be nearly a minute wrong while watchOS throttles an
  /// Always-On screen. Showing whole minutes (or “<1 min”) makes that cadence
  /// honest, while the isolated minute schedule avoids waking the rest of the
  /// hierarchy. A static progress fill would repeat that number less precisely
  /// and spend both pixels and compositing work, so the dimmed surface omits it.
  private func dimmedPhase(_ snapshot: WatchSnapshot) -> some View {
    TimelineView(.periodic(from: .now, by: 60)) { context in
      let lapsed = snapshot.phaseEndsAt.map { $0 <= context.date } ?? false

      VStack(alignment: .leading, spacing: 2) {
        // Wrapping is intentional. The longest real phase names need two lines
        // on 40 mm, and preserving every word matters more than uniform height.
        Text(snapshot.phaseTitle)
          .font(.system(size: 18, weight: .bold))
          .foregroundStyle(.white.opacity(lapsed ? 0.45 : 1))
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)

        if let countdown = dimmedCountdown(snapshot, at: context.date) {
          Text(countdown)
            .font(.system(size: 24, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  private func dimmedCountdown(_ snapshot: WatchSnapshot, at date: Date) -> String? {
    guard let endsAt = snapshot.phaseEndsAt else { return nil }
    let remaining = endsAt.timeIntervalSince(date)
    guard remaining > 0 else { return nil }
    if remaining < 60 { return "<1 min" }
    return "\(Int(ceil(remaining / 60))) min"
  }

  /// One full-width row is affordable without a basemap and gives the settled
  /// type dot, hex identity and quality figure enough size for arm's-length
  /// reading even when a six-character hash forces the overlay into one column.
  private func dimmedHeardRow(_ node: WatchHeardNode) -> some View {
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

  /// Phase and Top Heard in one panel.
  ///
  /// Rows are `[type dot] [hex ID] [SNR]`. The hex path hash is the identity,
  /// because a 1-byte hash frequently cannot be resolved to a single repeater;
  /// a name is appended only when the phone could resolve it unambiguously.
  private var statusPanel: some View {
    Button {
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
        followSuspendedUntil = nil
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
    Map(position: $camera, interactionModes: [.pan, .zoom]) {
      linkLines
      pingMarkers
      repeaterPins
      fixMarker
    }
    .mapStyle(settings.satellite ? .imagery : .standard)
    .onMapCameraChange(frequency: .onEnd) { context in
      noteRenderedRegion(context.region)
      noteCameraChange(context.region.center)
      correctPlacement(proxy)
    }
    .ignoresSafeArea(edges: .bottom)
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
    guard !isLuminanceReduced, force || isFollowing, let fix else { return }
    let center = centerPlacing(fix, proxy: proxy)
    programmaticCenter = center
    let region = MKCoordinateRegion(center: center, span: currentSpan)

    if force {
      // A tap is a rare, explicit request to move the map, so animation shows
      // the wearer what their action changed. Automatic follow is different:
      // the fix coordinate has already changed in this frame, and animating
      // the camera after it makes the puck wander before the map catches up.
      withAnimation(.easeInOut(duration: 0.25)) {
        camera = .region(region)
      }
    } else {
      // First placement, GPS steps and placement corrections all cut so the
      // puck stays visually fixed while the world moves beneath it.
      camera = .region(region)
    }
  }

  /// Region centre that puts [fix] midway between the top of the display and
  /// the top of the panel.
  ///
  /// MapKit centres the region in the map, so with a panel over the lower third
  /// the fix would sit low and partly behind it. Rather than predict how far to
  /// shift, this asks the map which coordinate is at the target point today and
  /// translates the camera by the difference — exact whatever the projection,
  /// the zoom, or the latitude.
  private func centerPlacing(
    _ fix: CLLocationCoordinate2D,
    proxy: MapProxy
  ) -> CLLocationCoordinate2D {
    // Before the first render there is nothing to translate against; centring
    // on the fix is the right opening move, and `correctPlacement` lifts it as
    // soon as the map reports back.
    guard let targetPoint,
      let renderedCenter,
      let atTarget = proxy.convert(targetPoint, from: .global)
    else { return fix }

    // Clamped so a bad conversion — an off-map point, a mid-animation read —
    // can never fling the camera somewhere the wearer has to chase.
    let lift = (fix.latitude - atTarget.latitude)
      .clamped(to: -currentSpan.latitudeDelta...currentSpan.latitudeDelta)
    return CLLocationCoordinate2D(
      latitude: renderedCenter.latitude + lift,
      longitude: fix.longitude
    )
  }

  /// Nudge the camera once the map reports where things really landed.
  ///
  /// The first placement runs before any render, and a zoom changes the scale
  /// underneath us, so placement is a feedback loop rather than a calculation.
  /// The deadband is what stops it: each pass lands within a couple of points,
  /// the next sees no error worth fixing, and it settles.
  private func correctPlacement(_ proxy: MapProxy) {
    guard !isLuminanceReduced, isFollowing, let fix, let targetPoint,
      let point = proxy.convert(fix, to: .global)
    else { return }
    guard abs(point.y - targetPoint.y) > 6 else { return }
    recenterIfFollowing(proxy)
  }

  /// MapKit fits longitude to the watch's aspect ratio, so latitude is the one
  /// independent zoom value. A fresh install starts at 0.0045 degrees, about
  /// 500 m north-south, and later launches reuse the wearer's Crown setting.
  private var currentSpan: MKCoordinateSpan {
    MKCoordinateSpan(
      latitudeDelta: settings.mapLatitudeDelta,
      longitudeDelta: settings.mapLatitudeDelta
    )
  }

  /// Centre of the region MapKit last rendered — the fixed point every
  /// placement is measured against.
  @State private var renderedCenter: CLLocationCoordinate2D?

  /// Track the region MapKit actually rendered, so a Digital Crown zoom is not
  /// thrown away on the next follow update and so placement has a known
  /// starting point.
  private func noteRenderedRegion(_ region: MKCoordinateRegion) {
    renderedCenter = region.center
    // Before our first camera update this region belongs to `.automatic`,
    // which fits every annotation and can span a continent. It is not a wearer
    // choice and must never become the remembered zoom. Once we have driven
    // the camera, rendered spans include our requested value and later Digital
    // Crown changes, both of which should persist.
    guard programmaticCenter != nil else { return }

    // Only on a real change. Every follow update produces a camera change, and
    // writing an identical value would persist and invalidate on each one,
    // re-rendering the map for nothing.
    let rendered = region.span.latitudeDelta
    let stored = settings.mapLatitudeDelta
    guard stored > 0, abs(rendered - stored) / stored > 0.01 else { return }
    settings.mapLatitudeDelta = rendered
  }

  private func noteCameraChange(_ center: CLLocationCoordinate2D) {
    guard let expected = programmaticCenter else {
      // We have never driven the camera, so this is `.automatic` settling on
      // launch rather than a pan. Treating it as one would suspend following
      // before the first fix even arrives.
      return
    }

    let drift = distance(center, expected)

    // `.automatic` settles *after* our first request, centred on the annotation
    // cloud — measured 372 m from the fix — and that disagreement is not a pan.
    // Reading it as one suspended following for eight seconds at every launch,
    // and overwrote the expectation, so our own region landing then looked like
    // a second pan. Nothing counts as a pan until MapKit has confirmed a centre
    // we actually asked for.
    guard hasConfirmedRequestedCenter else {
      if drift <= Self.panTolerance { hasConfirmedRequestedCenter = true }
      return
    }

    guard drift > Self.panTolerance else {
      // Our own follow update landing.
      return
    }

    // The wearer moved the map. Stop fighting them, and drift back shortly.
    programmaticCenter = center
    let deadline = Date().addingTimeInterval(Self.resumeFollowAfter)
    followSuspendedUntil = deadline
    scheduleFollowResume(at: deadline)
  }

  /// Re-evaluate when the suspension lapses.
  ///
  /// `followSuspendedUntil` is only read during a render, and a stationary
  /// phone sends no updates to trigger one — without this the map would stay
  /// unfollowed indefinitely after a single pan.
  private func scheduleFollowResume(at deadline: Date) {
    resumeTask?.cancel()
    resumeTask = Task { @MainActor in
      let seconds = deadline.timeIntervalSinceNow
      if seconds > 0 {
        try? await Task.sleep(for: .seconds(seconds))
      }
      guard !Task.isCancelled, followSuspendedUntil == deadline else { return }
      // Clearing this drives the recentre, via `onChange` where a proxy is in
      // scope.
      followSuspendedUntil = nil
    }
  }

  @State private var resumeTask: Task<Void, Never>?

  private func distance(
    _ a: CLLocationCoordinate2D,
    _ b: CLLocationCoordinate2D
  ) -> CLLocationDistance {
    CLLocation(latitude: a.latitude, longitude: a.longitude)
      .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
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
    withAnimation(.linear(duration: remaining)) {
      remainingFraction = 0
    }

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
