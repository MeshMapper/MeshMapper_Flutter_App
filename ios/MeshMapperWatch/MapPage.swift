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

  var body: some View {
    ZStack(alignment: .top) {
      map
      chrome
    }
    .onChange(of: snapshot?.geo.you.map { "\($0.lat),\($0.lon)" }) { _, _ in
      recenterIfFollowing()
    }
    .onAppear { recenterIfFollowing() }
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

  // MARK: - Chrome

  private var chrome: some View {
    HStack(alignment: .top) {
      if let snapshot {
        CountdownPill(snapshot: snapshot)
      }
      Spacer()
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
    .padding(.horizontal, 6)
    .opacity(client.isStale ? 0.5 : 1.0)
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
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
    .background(.black.opacity(0.55), in: Capsule())
  }
}
