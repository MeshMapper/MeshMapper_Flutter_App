import CoreLocation
import MapKit
import SwiftUI

/// The map, drawn on Apple's basemap.
///
/// MeshMapper's own basemap cannot come along: `MKTileOverlay` is
/// `API_UNAVAILABLE(watchos)`, so the OpenFreeMap styles, the ArcGIS satellite
/// raster, and the coverage vector tiles have no route onto the wrist. Only
/// the data layer — ping colours, repeater pins, the fix — is MeshMapper's.
struct MapPage: View {
  @Environment(WatchSessionClient.self) private var client
  @Environment(WatchSettings.self) private var settings

  @State private var camera: MapCameraPosition = .automatic

  /// Centre we last drove the camera to, so a camera change can be attributed
  /// to the wearer rather than to our own follow updates.
  @State private var programmaticCenter: CLLocationCoordinate2D?
  @State private var followSuspendedUntil: Date?

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
  @State private var viewWidth: CGFloat = 0

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

  /// Width the panel's content actually gets: the display minus the overlay's
  /// horizontal padding (4 a side) and the panel's own (8 a side).
  private var panelContentWidth: CGFloat { max(0, viewWidth - 24) }

  /// Whether there is room to set the phase title and the countdown *beside*
  /// the bar rather than on top of it.
  ///
  /// Budget: ~52 pt for the longest phase title, ~38 for the countdown, two
  /// 6 pt gaps, and ~64 left for the bar so it still reads as a gauge. A 46 mm
  /// screen has 184 pt to spend and a 40 mm one has 138, so the two sizes get
  /// genuinely different treatments instead of the small one being squeezed.
  private var labelsFitBesideBar: Bool { panelContentWidth >= 160 }

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
      map(proxy)

      // One panel in the top-leading corner carrying phase and Top Heard.
      //
      // Earlier versions floated the countdown in the opposite corner and drew
      // into the safe areas to reach the edges. On real hardware both got
      // clipped by the display curvature — the simulator renders a flat
      // rectangle and never shows it. The safe area is honoured now, and
      // merging the two overlays means there is no second corner to lose.
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
      .padding(.horizontal, 4)
      .padding(.top, 2)
    }
    .background(
      GeometryReader { geo in
        Color.clear
          .onAppear { viewWidth = geo.size.width }
          .onChange(of: geo.size.width) { _, width in viewWidth = width }
      }
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
          // Two columns when they fit, one when they don't. A 3-byte zone's
          // six-character hashes plus SNR will not fit two columns on a 40 mm
          // screen, and truncating the ID is not an option — it is the
          // repeater's identity. ViewThatFits picks by measurement rather than
          // by a guess about screen size.
          ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: columnGap) {
              heardColumn(Array(heard.prefix(2)))
              heardColumn(Array(heard.dropFirst(2)))
            }
            VStack(alignment: .leading, spacing: 2) {
              ForEach(heard) { heardRow($0) }
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 5)
      .frame(maxWidth: .infinity, alignment: .leading)
      // Blurred material rather than flat translucency: a 70% black panel
      // lets bright basemap labels bleed through and fight the SNR digits.
      // Blurring the map behind the panel removes the competing detail.
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

  /// Gutter between the two heard columns. Wider where there is room, so they
  /// read as columns rather than one run-on block hugging the left edge.
  /// Widening it also feeds `ViewThatFits`, which will drop to one column if
  /// the roomier pair no longer fits.
  private var columnGap: CGFloat { labelsFitBesideBar ? 18 : 10 }

  /// One column of heard rows.
  private func heardColumn(_ nodes: [WatchHeardNode]) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      ForEach(nodes) { heardRow($0) }
    }
  }

  /// `[type dot] [hex ID] [SNR]`, sized to its content.
  ///
  /// Content-sized on purpose: a greedy row always "fits", which would stop
  /// `ViewThatFits` from ever rejecting the two-column layout.
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
      TimelineView(.periodic(from: .now, by: 1)) { context in
        if labelsFitBesideBar {
          // Big screens have width to spare, so spend it on legibility: phase
          // name and remaining time both stand clear of the track, and the bar
          // is left as a pure gauge.
          HStack(spacing: 6) {
            phaseTitle(snapshot)
            track(snapshot, at: context.date)
            countdown(snapshot, at: context.date)
          }
        } else {
          // Small screens cannot afford two label columns, so the one label
          // that matters rides on the bar. Countdown when a phase is running,
          // otherwise its name.
          track(snapshot, at: context.date)
            .overlay(alignment: .trailing) {
              Group {
                if snapshot.phaseEndsAt.map({ $0 > context.date }) == true {
                  countdown(snapshot, at: context.date)
                } else {
                  phaseTitle(snapshot)
                }
              }
              // The fill slides under the label, so a shadow keeps it readable
              // against both the filled and empty parts of the track.
              .shadow(color: .black.opacity(0.7), radius: 1.5)
              .padding(.trailing, 6)
            }
        }
      }
      .frame(height: 15)
    }
  }

  /// The depleting track. Greedy on purpose — it takes whatever width the
  /// labels beside it leave.
  private func track(_ snapshot: WatchSnapshot, at date: Date) -> some View {
    GeometryReader { geo in
      ZStack(alignment: .leading) {
        Capsule().fill(.white.opacity(0.16))
        Capsule()
          .fill(snapshot.pingColor.map(Color.init) ?? .accentColor)
          .frame(width: geo.size.width * (snapshot.phaseRemainingFraction(at: date) ?? 0))
      }
    }
  }

  private func phaseTitle(_ snapshot: WatchSnapshot) -> some View {
    Text(snapshot.phaseTitle)
      .font(.system(size: 10, weight: .semibold))
      .foregroundStyle(.white)
      .lineLimit(1)
      .truncationMode(.tail)
  }

  /// Fixed width because `Text(timerInterval:)` otherwise reserves room for the
  /// widest value it might ever show, which would starve the track.
  @ViewBuilder
  private func countdown(_ snapshot: WatchSnapshot, at date: Date) -> some View {
    if let endsAt = snapshot.phaseEndsAt, endsAt > date {
      Text(timerInterval: date...endsAt, countsDown: true)
        .font(.system(size: 11, weight: .bold).monospacedDigit())
        .foregroundStyle(.white)
        .frame(width: 38, alignment: .trailing)
    }
  }

  /// Shrink the rows for longer path hashes, the same way `RepeaterIdChip`
  /// does on the phone. A 3-byte zone yields 6-character IDs, which at full
  /// size would run the box across a 40 mm screen.
  private var rowFontSize: CGFloat {
    let widest = heard.map(\.id.count).max() ?? 2
    if widest > 4 { return 9 }
    if widest > 2 { return 10 }
    return 11
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
      let linked = Set(snapshot.geo.linkedRepeaterIds)
      ForEach(snapshot.geo.repeaters.filter { linked.contains($0.id) }) { repeater in
        MapPolyline(coordinates: [
          fix,
          CLLocationCoordinate2D(latitude: repeater.lat, longitude: repeater.lon),
        ])
        .stroke(Color(repeater.color).opacity(0.7), lineWidth: 1.5)
      }
    }
  }

  @MapContentBuilder
  private var pingMarkers: some MapContent {
    if let snapshot {
      ForEach(snapshot.geo.pings) { ping in
        Annotation("", coordinate: CLLocationCoordinate2D(latitude: ping.lat, longitude: ping.lon)) {
          // Squares, matching the iOS map's ping markers.
          Rectangle()
            .fill(Color(ping.color))
            .frame(width: 5, height: 5)
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
    guard force || isFollowing, let fix else { return }
    let center = centerPlacing(fix, proxy: proxy)
    programmaticCenter = center
    withAnimation(.easeInOut(duration: 0.25)) {
      camera = .region(MKCoordinateRegion(center: center, span: currentSpan))
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
    guard isFollowing, let fix, let targetPoint,
      let point = proxy.convert(fix, to: .global)
    else { return }
    guard abs(point.y - targetPoint.y) > 6 else { return }
    recenterIfFollowing(proxy)
  }

  /// Preserve whatever zoom the wearer picked with the Digital Crown.
  ///
  /// The initial span is deliberately wide (~3 km): wardriving is about what
  /// is around you, and a tighter default opens with every nearby repeater
  /// off-screen.
  @State private var currentSpan = MKCoordinateSpan(
    latitudeDelta: 0.03,
    longitudeDelta: 0.03
  )

  /// Centre of the region MapKit last rendered — the fixed point every
  /// placement is measured against.
  @State private var renderedCenter: CLLocationCoordinate2D?

  /// Track the region MapKit actually rendered, so a Digital Crown zoom is not
  /// thrown away on the next follow update and so placement has a known
  /// starting point.
  private func noteRenderedRegion(_ region: MKCoordinateRegion) {
    currentSpan = region.span
    renderedCenter = region.center
  }

  private func noteCameraChange(_ center: CLLocationCoordinate2D) {
    guard let expected = programmaticCenter else {
      // We have never driven the camera, so this is `.automatic` settling on
      // launch rather than a pan. Treating it as one would suspend following
      // before the first fix even arrives.
      return
    }
    guard distance(center, expected) > Self.panTolerance else {
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
