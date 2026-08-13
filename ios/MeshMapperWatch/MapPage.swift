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

  var body: some View {
    ZStack {
      map

      // Top Heard sits hard against the upper-left and the countdown against
      // the lower-right, mirroring the phone's map so the two read the same
      // way at a glance.
      VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top) {
          topHeardBox
          Spacer(minLength: 0)
          recenterButton
        }
        Spacer(minLength: 0)
        HStack(alignment: .bottom) {
          staleBadge
          Spacer(minLength: 0)
          if let snapshot {
            CountdownPill(snapshot: snapshot)
          }
        }
      }
      .padding(.horizontal, 5)
      .padding(.bottom, 4)
      // Draw into both safe areas so the two corners are actually corners.
      // The top strip is free because the box is left-aligned and the system
      // clock is right-aligned; the bottom strip is otherwise dead space that
      // was pushing the countdown well clear of the edge.
      .ignoresSafeArea(edges: [.top, .bottom])
    }
    .sheet(isPresented: $showingNodes) {
      NavigationStack {
        NodeListView()
          .navigationTitle("Heard")
          .navigationBarTitleDisplayMode(.inline)
      }
    }
    .onChange(of: snapshot?.geo.you.map { "\($0.lat),\($0.lon)" }) { _, _ in
      recenterIfFollowing()
    }
    .onAppear {
      recenterIfFollowing()
      #if DEBUG
      // Lets the sheet layout be captured and iterated on headlessly; the
      // simulator has no way to tap the bar.
      if UserDefaults.standard.bool(forKey: "MeshMapperShowNodeSheet") {
        showingNodes = true
      }
      #endif
    }
  }

  /// "Top Heard" — the phone's map overlay, reproduced on the wrist.
  ///
  /// Rows are `[type dot] [hex ID] [SNR]`. The hex path hash is the identity,
  /// because a 1-byte hash frequently cannot be resolved to a single repeater;
  /// a name is appended only when the phone could resolve it unambiguously.
  private var topHeardBox: some View {
    Button {
      showingNodes = true
    } label: {
      VStack(alignment: .leading, spacing: 2) {
        Text("TOP HEARD")
          .font(.system(size: 8, weight: .medium))
          .foregroundStyle(.white.opacity(0.55))
          .kerning(0.5)

        if heard.isEmpty {
          Text("---")
            .font(.system(size: rowFontSize, design: .monospaced))
            .foregroundStyle(.white.opacity(0.4))
        } else {
          ForEach(heard) { node in
            HStack(spacing: 4) {
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
              }
            }
            .lineLimit(1)
            .fixedSize()
          }
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 5)
      // Blurred material rather than flat translucency: a 70% black panel
      // lets bright basemap labels bleed through and fight the SNR digits.
      // Blurring the map behind the box removes the competing detail entirely.
      .background(.ultraThinMaterial, in: .rect(cornerRadius: 10, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: 10, style: .continuous)
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
  private var recenterButton: some View {
    if !isFollowing, fix != nil {
      Button {
        followSuspendedUntil = nil
        recenterIfFollowing(force: true)
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

  private var map: some View {
    Map(position: $camera, interactionModes: [.pan, .zoom]) {
      linkLines
      pingMarkers
      repeaterPins
      fixMarker
    }
    .mapStyle(settings.satellite ? .imagery : .standard)
    .onMapCameraChange(frequency: .onEnd) { context in
      noteCameraChange(context.region.center)
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

  /// Stale data must never read as live data.
  @ViewBuilder
  private var staleBadge: some View {
    if client.isStale, let receivedAt = client.receivedAt {
      HStack(spacing: 2) {
        Image(systemName: "exclamationmark.triangle.fill")
          .font(.system(size: 7))
        Text(receivedAt, style: .relative)
          .font(.system(size: 9))
      }
      .foregroundStyle(.orange)
      .padding(.horizontal, 5)
      .padding(.vertical, 2)
      .background(.black.opacity(0.65), in: Capsule())
    }
  }

  // MARK: - Camera

  private func recenterIfFollowing(force: Bool = false) {
    guard force || isFollowing, let fix else { return }
    programmaticCenter = fix
    withAnimation(.easeInOut(duration: 0.25)) {
      camera = .region(
        MKCoordinateRegion(
          center: fix,
          span: currentSpan
        )
      )
    }
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
      followSuspendedUntil = nil
      recenterIfFollowing()
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

private struct CountdownPill: View {
  let snapshot: WatchSnapshot

  var body: some View {
    HStack(spacing: 3) {
      if let color = snapshot.pingColor {
        Circle()
          .fill(Color(color))
          .frame(width: 6, height: 6)
      }
      // Absolute deadline rendered by the system — no per-second traffic.
      if let endsAt = snapshot.phaseEndsAt, endsAt > Date() {
        Text(timerInterval: Date()...endsAt, countsDown: true)
          .font(.system(size: 12, weight: .medium).monospacedDigit())
      } else {
        Text(snapshot.phaseTitle)
          .font(.system(size: 11, weight: .medium))
          .lineLimit(1)
      }
    }
    .padding(.horizontal, 7)
    .padding(.vertical, 3)
    .background(.ultraThinMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
  }
}
