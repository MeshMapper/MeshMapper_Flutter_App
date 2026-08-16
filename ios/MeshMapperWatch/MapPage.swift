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
    if debugForcedDim { return true }
    if UserDefaults.standard.bool(forKey: "MeshMapperForceDimmed") { return true }
    #endif
    return environmentLuminanceReduced
  }

  #if DEBUG
  /// Drives a real full-luminance -> dimmed *transition* in the simulator,
  /// which `MeshMapperForceDimmed` alone cannot do: that flag only sets the
  /// state the page is born into, so it exercises the cold-dimmed path and
  /// never the glance path. Everything about the dim hold lives in the
  /// transition, so without this the only way to test it is Adam's wrist.
  ///
  /// Launch with `-MeshMapperAutoDimAfter <seconds>`.
  @State private var debugForcedDim = false
  #endif

  /// Content choice and display cadence are independent. A chosen readout can
  /// run at full luminance with a precise timer, and reduced luminance settles
  /// on that same approved surface because MapKit is not worth holding through
  /// a wrist-down.
  ///
  /// It settles there *after* the hold, not at the dim — see `dimmedMapHold`.
  private var showsMap: Bool {
    settings.mainPageContent == .map
      && (!isLuminanceReduced || isWithinDimmedMapHold)
  }

  /// Whether the phone should keep sending map geography.
  ///
  /// **Deliberately not `showsMap && isSelected`.** The hold below keeps
  /// drawing the pings the watch already has; it must not also keep the
  /// phone's geo claim open. `WatchBridgeService` only schedules suppression
  /// 15 s out, so a glance already costs about 21 s of geo — 5.9 s of map plus
  /// that delay — and holding the claim for the hold's duration as well would
  /// roughly double it, for a map the wearer was looking at either way.
  private var needsMapGeo: Bool {
    settings.mainPageContent == .map && !isLuminanceReduced && isSelected
  }

  /// How long the map keeps drawing after the display dims.
  ///
  /// **The dim is not the wrist coming down.** watchOS drops to reduced
  /// luminance about 5.9 seconds into a glance — 33 lifts measured, 14 of them
  /// inside a 0.49 s band, seven between 5.88 and 5.91 s — and the *clock face*
  /// dims in about the same time, so this is the platform's full-brightness
  /// window rather than anything this app can hold on to. The display stays
  /// legible: "the screen does get a bit dimmer but the level is relatively
  /// high still."
  ///
  /// `showsMap` treated that as nobody looking and tore the whole MapKit
  /// subtree down mid-glance. The wearer's report: "the watch often falls back
  /// to the always on state very rapidly despite still being in the lifted
  /// position. This can make the map flicker on and disappear while a user is
  /// looking at it."
  ///
  /// Twenty seconds covers a deliberate glance. It leaves the *radio* alone —
  /// `needsMapGeo` above is untouched by the hold — but it is not free: MapKit
  /// stays constructed and rendering for the duration, which is the cost the
  /// Always-On readout was introduced to avoid. Twenty seconds of it per
  /// glance is the trade; a wrist-down's worth would not be.
  private static let dimmedMapHold: TimeInterval = 20


  /// When the display last dimmed, or nil at full luminance.
  @State private var dimmedAt: Date?

  /// Exists to make a render happen at the end of the hold, not to decide when
  /// the hold ends — see `isWithinDimmedMapHold` for why that distinction is
  /// load-bearing.
  @State private var dimmedMapHoldTask: Task<Void, Never>?

  /// Whether the dim is recent enough that the wearer is plausibly still
  /// reading the map.
  ///
  /// **A missing timestamp means hold — but only if this page has been seen at
  /// full luminance.** `dimmedAt` is written by `onChange`, which runs *after*
  /// the body evaluation that first sees reduced luminance. Defaulting to "not
  /// holding" would therefore give that first frame `showsMap == false` and
  /// only restore the map on the update the callback provokes — turning the
  /// flicker this fixes into a teardown and a full rebuild, complete with a
  /// fresh camera anchor, at the exact moment the wearer is looking at it.
  ///
  /// `hasBeenBright` is what keeps that default from swallowing the Always-On
  /// design. A page that *appeared* already dimmed was never mid-glance, and
  /// without this it opened straight onto MapKit — measured, not theorised: a
  /// force-dimmed cold launch built the map subtree until this guard existed.
  ///
  /// **Past that, read the clock rather than a flag the expiry task cleared.**
  /// watchOS suspends this app within about a second of the dim — measured by
  /// the removed hitch detector, which lost 7.42 s of an 8.20 s wrist-down,
  /// 12.89 of 13.63, 23.01 of 23.99 — so `dimmedMapHoldTask` cannot be relied
  /// on to fire on time, and a boolean it owns would sit `true` for a whole
  /// wrist-down. Evaluating the timestamp means every render that actually
  /// happens gets the right answer, whenever it happens.
  ///
  /// That still needs a render to happen at all, which is what
  /// `dimmedMapHoldTicker` is for.
  /// Whether a dim arriving right now could hold anything.
  ///
  /// The same conditions `isWithinDimmedMapHold` applies, minus the ones that
  /// only make sense once a hold exists. Kept separate so arming can be
  /// skipped entirely rather than armed and then rejected on every render.
  private var canHoldMapThroughDim: Bool {
    settings.mainPageContent == .map && isSelected && hasBeenBright
  }

  private var isWithinDimmedMapHold: Bool {
    guard isSelected, isLuminanceReduced, hasBeenBright, !isDimmedMapHoldExpired
    else {
      return false
    }
    guard let dimmedAt else { return true }
    return Date().timeIntervalSince(dimmedAt) < Self.dimmedMapHold
  }

  /// Latched by the expiry task or the ticker, so a hold that has ended cannot
  /// be revived by `dimmedAt` being cleared out from under it.
  @State private var isDimmedMapHoldExpired = false

  /// Whether this page has been *watched* — selected and at full luminance —
  /// at some point since its state was created.
  ///
  /// Only then can a dim be part of a glance rather than the state the page was
  /// born into. It is deliberately not cleared by the view lifecycle: doing so
  /// broke the feature on hardware, because watchOS re-hosts the page at the
  /// dim and the reset landed mid-glance. Fresh `@State` already covers the
  /// case it was meant to, since a page SwiftUI genuinely rebuilds starts
  /// `false`.
  ///
  /// What it guards is narrower than an earlier comment here claimed. An
  /// off-screen page is already excluded — `isWithinDimmedMapHold` checks
  /// `isSelected` directly. This covers the two cases that check cannot see: a
  /// page that appeared already dimmed, and one selected for the first time
  /// while dimmed. Neither is a glance in progress.
  @State private var hasBeenBright = false

  @State private var camera: MapCameraPosition = .automatic

  /// Non-nil once we have driven the camera. Assignment is not proof that
  /// MapKit rendered the request, but it is the first half of the span
  /// handshake that keeps `.automatic` from becoming the remembered zoom.
  ///
  /// It doubles as the in-memory half of the centre seed: it is by definition
  /// the last place we drove the camera to, so a rebuilt map can be restored
  /// from it without waiting on a fix.
  @State private var programmaticCenter: CLLocationCoordinate2D?

  /// Whether *this* native map has been given a region of ours.
  ///
  /// Scoped to the map's lifetime like `hasConfirmedRequestedSpan`, and for the
  /// same reason: `MapPage` survives a wrist drop while the `Map` inside it does
  /// not, so a flag scoped to the page would claim a freshly built map was
  /// already anchored. Cleared in `mapContent`'s `onAppear`.
  ///
  /// This is what makes the anchor idempotent. Follow re-asserts on every geo
  /// update and that is fine; the anchor must fire exactly once per map, or a
  /// wearer with Follow off would have their Crown zoom overwritten by a
  /// re-assert on every panel resize.
  @State private var hasAssertedRegion = false

  /// Span counterpart to the centre handshake: MapKit can report its old
  /// `.automatic` fit after we assign a region, so assignment alone is not
  /// evidence that a rendered zoom came from us.
  ///
  /// Scoped to the *native map's* lifetime, not the page's. Dimming tears the
  /// map subtree down while `MapPage` — and therefore this `@State` — survives,
  /// so a confirmation earned before a wrist drop would otherwise still be
  /// standing when a freshly built `Map` emits its first region. Nothing proves
  /// that region is ours, and with the handshake already satisfied
  /// `noteRenderedRegion` would bank it as a Crown zoom and overwrite the
  /// wearer's saved span. `mapContent` clears it on appear so every native map
  /// re-earns the confirmation.
  ///
  /// **Load-bearing, and measured so.** The simulator gave no support for this
  /// at all — three teardown cycles, 0.0% drift every time — and it was written
  /// as speculative hardening. Hardware disagreed immediately. Once the camera
  /// falls into `.automatic` it reports a continental fit on *every* subsequent
  /// rebuild: twenty consecutive callbacks at 34.364390 degrees, ~3,800 km,
  /// against a requested 0.000500. Each one arrives at a freshly built map with
  /// this flag cleared, so the 25% gate rejects it and the wearer's saved zoom
  /// survives a completely broken camera. Without the reset, the first of those
  /// twenty would have been banked as a Crown zoom and persisted.
  ///
  /// This protects the *setting*, not the view. The camera getting stuck is a
  /// separate defect — see `recenterIfFollowing`.
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

  /// The panel's measured height, which is what the camera inset needs and,
  /// unlike its position, does not change while a page transition is animating.
  @State private var panelHeight: CGFloat = 0
  @State private var latchedTopSafeAreaInset: CGFloat = 0
  @State private var currentTopSafeAreaInset: CGFloat = 0
  @State private var bottomSafeAreaInset: CGFloat = 0

  /// Only one subtree sets this, but every *other* subtree still contributes
  /// the default. Taking `nextValue()` unconditionally would let a later
  /// sibling's `.zero` overwrite the real measurement, so empties are ignored.
  ///
  /// This carries the panel's **height**, never its position. Position was a
  /// runaway loop: an interactive page swipe translates the page, so a global
  /// frame changes every frame, which changed the camera inset, which
  /// re-framed the map, which invalidated layout, which re-measured. The watch
  /// wedged with a blurred half-finished transition — 21,611 MapKit
  /// reconfigurations and 4,300 body evaluations per second, main thread never
  /// free. Height does not change when the page moves, so the cycle cannot
  /// close. A programmatic selection change never exposes those intermediate
  /// positions, which is why only a real swipe reproduced it.
  private struct PanelHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
      let next = nextValue()
      if next > 0 { value = next }
    }
  }

  /// How much of the display the status panel is covering, handed to MapKit so
  /// it frames the camera in the band that remains visible.
  ///
  /// Derived from the panel's height plus the gap it leaves beneath itself,
  /// which reconstructs exactly what a bottom-anchored panel occupies without
  /// asking where it currently is. Measured rather than assumed because the
  /// height changes with content — one column or two, with or without heard
  /// rows — and a stale constant would drift the fix off centre precisely when
  /// the panel grew.
  private var panelCameraInset: CGFloat {
    guard panelHeight > 0 else { return 0 }
    let gapBeneath = curvedPanelHorizontalInset == nil
      ? bottomSafeAreaInset
      : panelBottomGap
    // Clamped: an inset approaching the display height would leave MapKit no
    // band to frame, and nothing about a status panel justifies that.
    let limit = WKInterfaceDevice.current().screenBounds.height * 0.75
    return min(max(0, panelHeight + gapBeneath), limit)
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
      // **Both items stay in the toolbar at all times.** They used to be wrapped
      // in `if !isLuminanceReduced`, and removing them at the dim changes the
      // toolbar's structure, which re-hosts this page and rebuilds the entire
      // MapKit subtree underneath it. Measured on a Series 9: a
      // `map-subtree-appeared` 0.13 s after every single `hold-armed`, with the
      // old subtree discarded 0.09 s later — a full teardown, fresh camera
      // anchor and basemap repaint, right under the wearer's eye. Adam saw it
      // as the map jumping as the display faded. With the items always present
      // the dim rebuilds nothing at all.
      //
      // Hidden by value rather than by presence, and hidden *properly*:
      // `.opacity(0)` alone leaves a live button, and `.allowsHitTesting`
      // covers ordinary touch but neither disables the action nor takes it out
      // of the accessibility tree. Start transmits on a single tap with no
      // confirmation, so a VoiceOver focus carried across the dim could fire
      // it on an invisible control. `hiddenWhileDimmed` disables and
      // accessibility-hides as well; all three are value changes, so the
      // toolbar's structure stays fixed.
      .toolbar {
        ToolbarItem(placement: .topBarLeading) {
          mainPageToggle.hiddenWhileDimmed(isLuminanceReduced)
        }
        ToolbarItem(placement: .topBarTrailing) {
          trailingToolbarButton.hiddenWhileDimmed(isLuminanceReduced)
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
        // Time the readout->map switch, which rebuilds the same MapKit tree a
        // wrist raise does — the one thing about a raise that is reproducible
        // without a wrist, since Always-On cannot be entered here. Pair it with
        // `-layout.mainPageContent readout` or the flip is a no-op against a
        // map that is already showing, which reads as a suspiciously fast
        // result rather than as no measurement at all.
        let autoDim = UserDefaults.standard.integer(forKey: "MeshMapperAutoDimAfter")
        if autoDim > 0 {
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(autoDim))
            WakeLog.note("debug-forcing-dim")
            debugForcedDim = true
          }
        }
        if UserDefaults.standard.bool(forKey: "MeshMapperTimeSwitchToMap") {
          Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            NSLog("[switch] requesting map at %f", Date().timeIntervalSince1970)
            settings.mainPageContent = .map
          }
        }
        #endif
        client.setMapGeoNeeded(needsMapGeo)
        // A page that opens selected and bright is a glance in progress; one
        // that opens dimmed or behind another page is not, and must not hold a
        // map it never showed.
        armGlanceIfWatched()
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
        noteSelection(selected)
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
        noteLuminance(reduced: reduced)
        if reduced { disarmToolbarControl() }
        #if DEBUG
        // The reference timestamp for a wrist-raise measurement. Nothing else
        // marks the moment the wrist came up, so without this the `map` and
        // `span` lines have no zero to be measured against.
        WakeLog.note(reduced ? "wrist-down" : "wrist-up")
        #endif
      }
      // Deliberately does NOT touch the hold. Apple's guidance is that Always On
      // keeps views in the hierarchy, but hardware also collapses the
      // navigation bar at the dim where the simulator does not — and the
      // re-host that causes fired this handler mid-glance, which destroyed the
      // hold about a second in and put the wearer straight back on the readout.
      // `@State` already gives the right answer for free: if SwiftUI really
      // destroys this page, `hasBeenBright` goes with it and a page rebuilt
      // while dimmed starts unarmed. If it survives, so should the glance.
      .onDisappear { disarmToolbarControl() }
      // A main-actor "hitch" detector lived here — a 250 ms tick that logged
      // whenever it lost more than a second — meant to decide whether the 6.1 s
      // wake stall was the app being descheduled or SwiftUI deferring the
      // rebuild. It was removed because it cannot tell those apart from the one
      // thing that always happens: watchOS suspends this app while the wrist is
      // down, so the tick simply stops. Measured, it fired on every single wake
      // at almost exactly the wrist-down duration — 7.42 s against 8.20 s,
      // 12.89 against 13.63, 23.01 against 23.99. It reports suspension and
      // calls it a stall.
      //
      // Its silence was equally worthless, and had already been cited as
      // evidence that the stall "did not recur". Anything replacing it must
      // establish the app was actually scheduled — a suspension-aware signal
      // such as `scenePhase`, not a timer that cannot observe its own absence.
  }

  private var pageContent: some View {
    ZStack {
      if showsMap {
        // Keep the map inside this branch: constructing even map
        // infrastructure behind the readout would defeat its battery purpose.
        //
        // There is deliberately no `MapReader` here. One wrapped this content
        // while `centerPlacing` and `correctPlacement` translated the camera
        // through `proxy.convert`; camera placement is now `.safeAreaPadding`,
        // which insets MapKit's own framing, so no coordinate conversion
        // happens anywhere in this file. The proxy was threaded through six
        // functions unread. Do not reintroduce a reader to place the camera —
        // see the handoff: the map's SwiftUI frame is not the map, and any
        // offset computed from view geometry under-shoots.
        mapContent
      } else {
        readoutContent
      }
    }
    // Attached as a background rather than as a sibling in the ZStack. As a
    // sibling it enters the stack exactly when luminance drops, which
    // re-identifies the branch beside it and rebuilt the whole MapKit subtree
    // at the dim — measured on hardware as `map-subtree-appeared` 0.13 s after
    // every `hold-armed`, and visible on the wrist as the map jumping right
    // as it dims. A background cannot change the identity of the content it
    // decorates.
    .background(dimmedMapHoldTicker)
  }

  /// Asks watchOS to render this page again when the hold ends.
  ///
  /// **Without this the hold could not end during a real wrist-down at all.**
  /// The clock in `isWithinDimmedMapHold` only decides the answer for renders
  /// that happen, and a suspended app renders nothing: the last frame drawn
  /// stays on the Always-On display until something asks for another. Hold the
  /// map and then suspend, and the map — not the approved readout — would be
  /// the Always-On surface for the whole time the wrist was down.
  ///
  /// A timeline entry is the supported way to ask for that render — the same
  /// mechanism the readout's coarse countdown uses while dimmed, though not
  /// literally the same wake, since that countdown is not in the tree while the
  /// map is held. watchOS may still coalesce them into one cadence. The
  /// schedule repeats rather than naming the single boundary: a two-entry
  /// `.explicit` schedule can be exhausted by an early re-query and then never
  /// ask for another render at all, which would strand the map on the display.
  /// Repeating entries cannot run out, and the ticker leaves the tree entirely
  /// once the hold is expired, so nothing keeps asking.
  ///
  /// Always-On throttles these updates to roughly one a minute, so the readout
  /// may return somewhat after twenty seconds. Nobody is looking by then — the
  /// point is that it returns without needing the wrist.
  @ViewBuilder
  private var dimmedMapHoldTicker: some View {
    if isLuminanceReduced, !isDimmedMapHoldExpired, let dimmedAt {
      TimelineView(.periodic(from: dimmedAt, by: Self.dimmedMapHold)) { context in
        Color.clear
          .frame(width: 0, height: 0)
          .onChange(of: context.date) { _, _ in
            // **A schedule entry arriving is not proof its deadline arrived.**
            // Entering Always On changes the timeline's cadence, which
            // re-queries the schedule, and SwiftUI can hand over the next entry
            // there and then. An earlier version treated the date changing as
            // the boundary and called this directly: on a Series 9 it expired
            // the hold 0.82, 0.85, 0.94 and 1.05 s after the dim, four glances
            // out of four, while the simulator — which never enters Always On,
            // so never changes cadence — passed every time.
            //
            // The clock is the authority, exactly as it is in
            // `isWithinDimmedMapHold`. This callback only decides whether the
            // render that just happened is the one that ends the hold.
            guard Date().timeIntervalSince(dimmedAt) >= Self.dimmedMapHold else {
              return
            }
            expireDimmedMapHold()
          }
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

  private func noteLuminance(reduced: Bool) {
    guard reduced else {
      armGlanceIfWatched()
      resetDimmedMapHold()
      return
    }
    // Nothing to hold means nothing to arm. `isWithinDimmedMapHold` rejects
    // all of these anyway, but arming would still start a task and put a
    // timeline in the tree, asking watchOS for an Always-On render that can
    // only ever decide there was no hold.
    guard canHoldMapThroughDim else { return }
    dimmedMapHoldTask?.cancel()
    dimmedAt = Date()
    isDimmedMapHoldExpired = false
    #if DEBUG
    WakeLog.note("hold-armed bright \(hasBeenBright) selected \(isSelected)")
    #endif
    // Fires only while the app happens to still be scheduled, which is roughly
    // the first second after the dim. `dimmedMapHoldTicker` is what covers the
    // rest; this is here so a glance that keeps the app alive ends the hold at
    // exactly the right moment rather than at the next system update.
    dimmedMapHoldTask = Task { @MainActor in
      try? await Task.sleep(for: .seconds(Self.dimmedMapHold))
      guard !Task.isCancelled else { return }
      expireDimmedMapHold()
    }
  }

  private func expireDimmedMapHold() {
    dimmedMapHoldTask?.cancel()
    dimmedMapHoldTask = nil
    guard !isDimmedMapHoldExpired else { return }
    isDimmedMapHoldExpired = true
    #if DEBUG
    WakeLog.note("hold-expired")
    #endif
  }

  private func resetDimmedMapHold(_ reason: String = "luminance") {
    #if DEBUG
    if dimmedAt != nil || isDimmedMapHoldExpired {
      WakeLog.note("hold-reset \(reason)")
    }
    #endif
    dimmedMapHoldTask?.cancel()
    dimmedMapHoldTask = nil
    dimmedAt = nil
    isDimmedMapHoldExpired = false
  }

  /// Ends both the hold and the glance that earned it. Only deselection does
  /// this: it is an explicit statement that the wearer is looking elsewhere,
  /// unlike a view-lifecycle callback, which on watchOS can fire for reasons
  /// that have nothing to do with whether anyone is looking.
  private func endDimmedMapHoldLifetime(_ reason: String) {
    resetDimmedMapHold(reason)
    #if DEBUG
    if hasBeenBright { WakeLog.note("hold-disarmed \(reason)") }
    #endif
    hasBeenBright = false
  }

  private func armGlanceIfWatched() {
    if isSelected, !isLuminanceReduced { hasBeenBright = true }
  }

  private func noteSelection(_ selected: Bool) {
    // A hold belongs to a glance at *this* page. Swiping away ends the glance,
    // whatever the display is doing.
    guard selected else {
      endDimmedMapHoldLifetime("deselected")
      return
    }
    armGlanceIfWatched()
  }

  private var mapContent: some View {
    ZStack {
      map
      mapOverlay
    }
    .onPreferenceChange(PanelHeightKey.self) { height in
      guard abs(height - panelHeight) > 0.5 else { return }
      panelHeight = height
      recenterIfFollowing()
    }
    .onChange(of: snapshot?.geo.you.map { "\($0.lat),\($0.lon)" }) { _, _ in
      recenterIfFollowing()
      // A first fix is the moment a map that had nothing to anchor to becomes
      // placeable. Idempotent, so this is a no-op on every later update.
      anchorCameraIfNeeded()
    }
    .onAppear {
      // A new native map has to re-earn the span handshake, and holds no region
      // of ours until one is asserted below.
      hasConfirmedRequestedSpan = false
      hasAssertedRegion = false
      #if DEBUG
      // Marks the MapKit subtree being rebuilt. This is the SwiftUI half of a
      // wrist raise only — the basemap paints later, with no callback of any
      // kind, so the gap from here to visible pixels needs a camera or an eye.
      WakeLog.note("map-subtree-appeared")
      // Read as a pair with `camera-after`. The span log cannot separate "we
      // never asserted a region" from "we asserted one and MapKit rendered its
      // own anyway", and those want different fixes:
      //
      //   before automatic=true,  after automatic=false, span still continental
      //     -> we asserted and were ignored; the assignment is not the lever
      //   before automatic=true,  after automatic=true
      //     -> `anchorCenter` was nil, so nothing was available to anchor to
      //   before automatic=false, after automatic=false, span continental
      //     -> the camera holds a region but MapKit is not honouring it
      WakeLog.note("camera-before \(cameraStateDescription)")
      #endif
      recenterIfFollowing()
      anchorCameraIfNeeded()
      #if DEBUG
      WakeLog.note("camera-after \(cameraStateDescription)")
      #endif
    }
    #if DEBUG
    // Separates "built twice" from "built, torn down, rebuilt". Every device
    // wake logs two appearances 50-70 ms apart, and the shape of the pair
    // decides where to look: an interleaved disappear means a genuine teardown,
    // two bare appearances mean two live instances.
    //
    // **The pair is settled, and it is not ours.** It is construct → construct
    // → discard the first, netting one live subtree. A probe placed as a bare
    // sibling above `pageContent`'s `if showsMap` doubled identically, and so
    // did one inside `readoutContent` on a launch with no MapKit anywhere —
    // so this is the whole page being built twice, not anything about the map.
    // Probes on the `NavigationStack` and the `TabView` each fired once, and
    // it survived both removing the hoisted stack entirely and making the
    // conditional Heard page unconditional. What remains is the vertical pager
    // building its selected page twice at launch. Nothing here can prevent it;
    // the cost is one discarded construction against a 0.104 s rebuild.
    .onDisappear { WakeLog.note("map-subtree-disappeared") }
    #endif
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
  private var mapOverlay: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer(minLength: 0)
        recenterButton
      }
      Spacer(minLength: 0)
      statusPanel
        .overlay(alignment: .top) {
          commandFailureBanner
            .padding(.horizontal, 4)
            // Aligning a guide below the banner with the panel's top puts the
            // transient immediately above the measured card. Unlike adding a
            // VStack row, an overlay contributes no size, so neither the
            // panel's signed-off placement nor its measured height can move.
            .alignmentGuide(.top) { dimensions in
              dimensions[.bottom] + 3
            }
        }
        .background(
          GeometryReader { geo in
            // Size, not frame: a global position moves with the page during
            // an interactive swipe and closes a layout feedback loop.
            Color.clear.preference(key: PanelHeightKey.self, value: geo.size.height)
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
      WatchPhaseBar(snapshot: snapshot, isLuminanceReduced: isLuminanceReduced)
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
  private var recenterButton: some View {
    if !isFollowing, fix != nil {
      Button {
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
    // pass. A Crown zoom holds it there across the useful range — measured
    // drift is 0.000000 degrees from 0.0002 up to about 21 degrees of span —
    // but *not* past roughly 22 degrees, where MapKit shifts the centre north
    // and leaves it there. `recentreAfterUserZoom` repairs that; the framing
    // here is not what breaks.
    //
    // Both edges matter. Insetting only the bottom centres the fix in
    // `0...panelTop`, which still includes the toolbar strip, and the puck then
    // reads high — obviously so on 46 mm, where the chrome is a smaller
    // fraction of the display.
    .safeAreaPadding(.top, currentTopSafeAreaInset)
    .safeAreaPadding(.bottom, panelCameraInset)
    .onMapCameraChange(frequency: .onEnd) { context in
      // `.onEnd` matters: the correction below must never run mid-gesture, or
      // it would fight the Crown while the wearer is still turning it.
      noteRenderedRegion(context.region, cameraCentre: context.camera.centerCoordinate)
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

  private func recenterIfFollowing(force: Bool = false) {
    // Every early return here leaves `camera` untouched, and an untouched
    // camera can still be `.automatic` — which fits every annotation and has
    // been measured rendering 34.4 degrees, about 3,800 km. Log which clause
    // bailed: "no fix" and "follow off" are indistinguishable in the span log
    // and want different fixes.
    #if DEBUG
    if !(showsMap && (force || isFollowing) && fix != nil) {
      WakeLog.note(
        "recenter-skipped showsMap \(showsMap) following \(isFollowing) "
          + "fix \(fix == nil ? "nil" : "yes") force \(force)"
      )
    }
    #endif
    guard showsMap, force || isFollowing, let fix else { return }
    // Centre on the fix itself. The camera inset already accounts for the
    // panel, so no compensating shift is needed and nothing has to be
    // corrected after the map reports back.
    //
    // A tap is a rare, explicit request to move the map, so animation shows the
    // wearer what their action changed. Automatic follow is different: the fix
    // coordinate has already changed in this frame, and animating the camera
    // after it makes the puck wander before the map catches up.
    applyRegion(center: fix, animated: force)
  }

  /// Guarantee this native map has a region of ours, whatever `recenterIfFollowing`
  /// decided.
  ///
  /// **`.automatic` is a terminal state, and this is what ends it.** Every early
  /// return in `recenterIfFollowing` leaves `camera` untouched, and an untouched
  /// camera can still be `.automatic` — which fits every annotation and was
  /// measured on a Series 9 rendering 34.364390 degrees of latitude, about
  /// 3,800 km. Nothing else in this file assigns a region, so once the camera
  /// landed there only a manual Crown zoom escaped it: twenty consecutive
  /// callbacks at that span, across five separate wrist raises.
  ///
  /// The wake log is specific about when it happens. Wakes preceded only by
  /// follow updates restored perfectly — first callback `drift 0.0%`, every
  /// time. The one wake that came back continental was the one preceded by a
  /// burst of Crown zooming, which suggests the interaction leaves `camera` in a
  /// state that does not survive the subtree teardown. This does not depend on
  /// that being the mechanism: it asserts a region regardless of how the camera
  /// got where it is.
  ///
  /// Follow governs *tracking*, not whether a region is ever asserted. Turning
  /// Follow off must not be able to strand the map at a continental span.
  private func anchorCameraIfNeeded() {
    guard showsMap, !hasAssertedRegion, let center = anchorCenter else { return }
    applyRegion(center: center, animated: false)
  }

  /// Where a map with no follow-driven centre should open.
  ///
  /// Ordered by how well each source reflects what the wearer last saw. With
  /// Follow off a *recent* centre wins over the live fix on purpose — restoring
  /// the view they left is the whole point, and jumping to the fix is precisely
  /// the tracking they turned off.
  ///
  /// The live fix outranks a stale one because this map cannot pan
  /// (`interactionModes: [.zoom]`), so opening on a centre the wearer has since
  /// travelled away from strands them somewhere they can only zoom. A stale
  /// centre is still preferred over nothing: it is a real place the wearer once
  /// was, which beats `.automatic` fitting every annotation at 3,800 km.
  private var anchorCenter: CLLocationCoordinate2D? {
    if isFollowing, let fix { return fix }
    if let programmaticCenter { return programmaticCenter }
    return settings.freshMapCenter ?? fix ?? settings.lastMapCenter
  }

  /// The one place `camera` is assigned, so every path records the centre and
  /// marks the map anchored.
  ///
  /// `span` defaults to the persisted zoom, which is right for every caller
  /// except the post-zoom correction: that one has to carry the span MapKit
  /// just rendered, or correcting the centre would also undo the wearer's zoom.
  private func applyRegion(
    center: CLLocationCoordinate2D,
    span: MKCoordinateSpan? = nil,
    animated: Bool
  ) {
    programmaticCenter = center
    hasAssertedRegion = true
    settings.noteMapCenter(center)
    let region = MKCoordinateRegion(center: center, span: span ?? currentSpan)

    // DO NOT re-add a "skip when the region is unchanged" guard here. One was
    // tried and reverted: it bought no measurable wake latency (0.43/0.46/0.47 s
    // against a 0.15 s sampling floor) and it removed a repair. This assignment
    // is not merely redundant — it is the only thing that re-asserts our region
    // over whatever the camera drifted to, including `.automatic`, whose
    // annotation fit spans a continent. Adam raised his wrist to a map showing
    // the whole United States while that guard was installed.
    if animated {
      withAnimation(.easeInOut(duration: 0.25)) {
        camera = .region(region)
      }
    } else {
      // First placement and GPS steps cut, so the puck stays visually fixed
      // while the world moves beneath it.
      camera = .region(region)
    }
  }

  #if DEBUG
  /// `positionedByUser` is included because a Crown zoom is the one interaction
  /// that precedes the stuck camera in the wake log, and it is the only public
  /// signal that MapKit rather than we last moved the camera.
  private var cameraStateDescription: String {
    "automatic \(camera == .automatic) byUser \(camera.positionedByUser) "
      + "anchored \(hasAssertedRegion) fix \(fix == nil ? "nil" : "yes") "
      + "following \(isFollowing)"
  }
  #endif

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
  private func noteRenderedRegion(
    _ region: MKCoordinateRegion,
    cameraCentre: CLLocationCoordinate2D
  ) {
    // Latched before anything below can assign the camera and clear it.
    let wasPositionedByUser = camera.positionedByUser

    // Deferred because the span write-back below has four early returns and the
    // centre needs repairing on every one of them — the northward shift arrives
    // on a zoom-out large enough that the write-back may well bail.
    defer {
      recentreAfterUserZoom(
        wasPositionedByUser: wasPositionedByUser,
        renderedSpan: region.span
      )
    }

    // A wearer who works the Crown on a map we never anchored has stated a
    // camera preference, and it outranks our seed. Without this, the sequence
    // "launch with no fix -> wearer zooms -> first fix arrives" ends with
    // `anchorCameraIfNeeded` replacing their zoom with the persisted span,
    // because `hasAssertedRegion` was still false. Marking it here retires the
    // anchor without asserting anything, which is exactly the intent: the map
    // is positioned, just not by us.
    if wasPositionedByUser {
      hasAssertedRegion = true
    }

    #if DEBUG
    if wasPositionedByUser, let fix {
      // Quantifies the zoom-anchor drift. The wearer reported that zooming in
      // loses the centre faster than zooming out; this is the number behind it,
      // and it should read near zero once the correction below has run.
      WakeLog.note(
        String(
          format: "user-zoom drift lat %.6f lon %.6f span %.6f",
          cameraCentre.latitude - fix.latitude,
          cameraCentre.longitude - fix.longitude,
          region.span.latitudeDelta
        )
      )
    }
    #endif

    // `.automatic` can report its annotation fit even after we assign our first
    // region, so `programmaticCenter != nil` proves only that a request was
    // made, not that MapKit rendered it. Persist nothing until the rendered
    // span confirms the request; later deviations are Crown zooms and remain
    // eligible for the normal write-back below.
    guard programmaticCenter != nil else { return }

    let rendered = region.span.latitudeDelta
    let requested = settings.mapLatitudeDelta
    guard rendered.isFinite, requested.isFinite, requested > 0 else { return }

    #if DEBUG
    WakeLog.note(
      String(
        format: "span rendered %.6f requested %.6f confirmed %@ drift %.1f%%",
        rendered, requested, hasConfirmedRequestedSpan ? "Y" : "N",
        abs(rendered - requested) / requested * 100
      )
    )
    #endif

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

  /// Put the fix back at the centre after the wearer has zoomed.
  ///
  /// **What actually drifts, measured on a Series 9.** A Crown zoom holds the
  /// camera centre exactly — drift is 0.000000 degrees through spans of 0.0002
  /// up to about 21 degrees. Past roughly 22 degrees MapKit moves the centre
  /// *north* and does not put it back: measured jumps of 0.074080 degrees
  /// (8.2 km) at a 24.5-degree span and 0.126004 degrees (14.0 km) at a
  /// 25.0-degree span. The shift is **sticky** — it survives every later zoom,
  /// including a zoom all the way back in to 0.000229, so the wearer ends up
  /// looking at a point 8-14 km north of themselves at street level. Only a
  /// wrist drop, which rebuilds the map, cleared it.
  ///
  /// That is exactly what was reported: "zoom out seems to stay centered
  /// initially, but zoom didn't stay centered (missed to the north,
  /// significantly). Re-centered after drop/raise."
  ///
  /// **This function was once deleted, and the deletion was a mistake worth
  /// recording.** An earlier reading of the same probe showed drift pinned at
  /// zero and concluded there was nothing to repair. That run had this
  /// correction installed: the probe samples at the start of the *next* camera
  /// change, so it was reading a centre this function had just repaired. The
  /// zero was the repair working. Before removing it again, remove it *first*
  /// and re-measure — a metric taken through a repair cannot evaluate it.
  ///
  /// **The span is preserved, not re-asserted.** Using `currentSpan` here would
  /// pull the zoom back to the persisted (and clamped) value on every turn of
  /// the Crown, which reads as the map refusing to zoom. Only the centre moves.
  ///
  /// **Termination.** Gated on `positionedByUser`, which MapKit sets for an
  /// interactive change and our own assignment clears, so this can trigger
  /// exactly one more camera change and that one does not re-enter. Confirmed
  /// on device: `byUser true` appears only after a real Crown zoom.
  ///
  /// Following only — with Follow off the camera is the wearer's.
  private func recentreAfterUserZoom(wasPositionedByUser: Bool, renderedSpan: MKCoordinateSpan) {
    guard wasPositionedByUser, isFollowing, let fix else { return }
    // Unconditional, like every other assertion in this file. When the centre
    // has not drifted this re-asserts the same region, which is the cheap case;
    // see `applyRegion` for what a "skip when unchanged" guard cost last time.
    applyRegion(center: fix, span: renderedSpan, animated: false)
  }

}

/// A phase-scoped progress animation rather than a one-second render clock.
///
/// `Text(timerInterval:)` owns its countdown without invalidating this view.
/// The fill is set once from the absolute deadline and driven to zero by a
/// single transform animation; one sleeping task wakes at the deadline solely
/// to retire the countdown and dim a claim the phone has not refreshed.
private struct WatchPhaseBar: View {
  let snapshot: WatchSnapshot
  /// Passed in rather than read from the environment so the DEBUG dim
  /// overrides on `MapPage` reach it — the whole panel is captured through
  /// them, and a bar that kept animating would be the one thing that did not.
  let isLuminanceReduced: Bool

  @State private var remainingFraction: CGFloat
  @State private var deadlineLapsed: Bool

  init(snapshot: WatchSnapshot, isLuminanceReduced: Bool) {
    self.snapshot = snapshot
    self.isLuminanceReduced = isLuminanceReduced
    let now = Date()
    _remainingFraction = State(
      initialValue: CGFloat(snapshot.phaseRemainingFraction(at: now) ?? 0)
    )
    _deadlineLapsed = State(
      initialValue: snapshot.phaseEndsAt.map { $0 <= now } ?? false
    )
  }

  /// Whether the fill should be animated at all, as opposed to snapped to the
  /// deadline's current truth and left there.
  ///
  /// **Reduced luminance stops it.** Always-On updates the screen at roughly
  /// one frame a minute, so a drain animation there buys no visible motion and
  /// spends energy anyway; Apple's Always-On guidance is to pause animations
  /// and drop subsecond work while the app is inactive. The map now stays
  /// constructed for up to `dimmedMapHold` seconds past the dim, which is
  /// exactly when this bar would otherwise keep animating over a screen nobody
  /// can see move.
  private var drainsFill: Bool {
    #if DEBUG
    // A/B harness for the drain's energy cost, under Settings -> Instruments.
    if WatchSettings.debugFreezesTimerBar { return false }
    #endif
    return !isLuminanceReduced
  }

  private var phaseKey: PhaseAnimationKey {
    PhaseAnimationKey(
      endsAtMs: snapshot.phaseEndsAtMs,
      durationMs: snapshot.phaseDurationMs,
      drainsFill: drainsFill
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
    ZStack(alignment: .leading) {
      Capsule().fill(.white.opacity(0.16))
      Capsule()
        .fill(snapshot.pingColor.map(Color.init) ?? .accentColor)
        // **A transform, not a width.** Animating `frame(width:)` re-runs
        // SwiftUI's layout for the whole panel on every frame of a drain that
        // lasts the entire phase; a leading-anchored scale is one affine
        // transform handed to the render server and left alone.
        //
        // **Scale the mask, not the capsule.** Scaling the capsule itself
        // squashes its end caps, so the bar started rounded and finished with
        // square ends — visible on the wrist at 15 pt tall, where an earlier
        // comment here guessed it would not be. Masking keeps the capsule's
        // own geometry untouched, so the leading cap stays round and only the
        // trailing edge becomes a flat cut, and the animated property is still
        // a single affine transform on a solid shape.
        .mask(alignment: .leading) {
          Rectangle()
            .scaleEffect(x: remainingFraction, y: 1, anchor: .leading)
        }
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
    // from the previous phase's endpoint before beginning its own drain. This
    // is also what makes the dim honest: the task re-runs when `drainsFill`
    // flips, so the frozen bar is snapped to the deadline's truth rather than
    // stranded wherever the cancelled animation happened to be.
    //
    // **A zero-duration animation, not `disablesAnimations`.** Suppressing the
    // transaction leaves the running drain in place, and interrupting a
    // transform animation reverts the layer to its model value — measured in
    // the simulator as a bar that snapped back to *full* at the dim and stayed
    // there, while the countdown beside it ran on. Replacing the animation
    // rather than opting out of one is what actually ends it.
    //
    // **And replacing it requires the value to actually change.** While a drain
    // runs, the *model* value here is already 0: `withAnimation` set it there at
    // the start and is interpolating only the presentation toward it. So this
    // assignment is a no-op precisely when the new truth is also 0 — which is
    // the stopped-session case — and the in-flight drain survives untouched.
    // Adam saw exactly that on the wrist: the title changed to "Ready" while
    // the fill kept draining to the old deadline. The dim never showed it
    // because a dim mid-phase has a non-zero truth, so the assignment was a
    // real change and did replace the animation.
    //
    // Hence the nudge: one zero-duration transaction to a value that is
    // certainly different, which SwiftUI must take and which abandons the
    // animation in flight, then the real one to the truth. Both are
    // zero-duration, so neither is visible.
    // The nudge must land in its own transaction. SwiftUI batches state changes
    // made in one run-loop turn, so a nudge and the real assignment written back
    // to back coalesce into a single change that nets to nothing — the very
    // no-op being escaped. `Task.yield()` separates them, which is the same
    // reason the drain below already yields before it starts.
    if remainingFraction == fraction {
      withAnimation(.linear(duration: 0)) {
        remainingFraction = fraction > 0.5 ? fraction - 0.001 : fraction + 0.001
      }
      await Task.yield()
    }
    withAnimation(.linear(duration: 0)) {
      remainingFraction = fraction
      deadlineLapsed = lapsed
    }

    #if DEBUG
    // Measure instead of reasoning about it: the stopped-session drain has now
    // survived one reasoned fix, so record what this task actually sees. If no
    // line appears on a stop, `phaseKey` did not change and the task never
    // re-ran; if one appears with `endsAt nil fraction 0.000` while the fill is
    // still visibly draining, the animation is outliving the state and no
    // assignment here will end it.
    WakeLog.note(
      String(
        format: "bar %@ endsAt %@ duration %@ fraction %.3f lapsed %@ drains %@",
        snapshot.phaseTitle,
        snapshot.phaseEndsAtMs.map { String(format: "%.0f", $0) } ?? "nil",
        snapshot.phaseDurationMs.map(String.init) ?? "nil",
        fraction,
        lapsed ? "yes" : "no",
        drainsFill ? "yes" : "no"
      )
    )
    #endif

    guard let endsAt = snapshot.phaseEndsAt else { return }
    let remaining = endsAt.timeIntervalSince(now)
    guard remaining > 0 else { return }

    if drainsFill {
      await Task.yield()
      withAnimation(.linear(duration: remaining)) {
        remainingFraction = 0
      }
    }

    // Retiring the deadline is one wake per phase, not per frame, so it stays
    // in place while dimmed. Losing it would leave a countdown asserting a
    // claim the phone has stopped confirming.
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
    /// Luminance participates only to stop and resume the drain. It belongs in
    /// the key so the dim cancels the running animation rather than leaving it
    /// interpolating against a screen that updates once a minute.
    let drainsFill: Bool
  }
}

extension Comparable {
  fileprivate func clamped(to limits: ClosedRange<Self>) -> Self {
    min(max(self, limits.lowerBound), limits.upperBound)
  }
}

extension View {
  /// Take a control out of service while the display is dimmed, without taking
  /// it out of the view tree.
  ///
  /// Presence is what must not change: wrapping toolbar items in an `if` alters
  /// the toolbar's structure, which re-hosts the page and rebuilds everything
  /// under it — measured on hardware as a full MapKit teardown 0.13 s into
  /// every dim. Every modifier here is a value change instead.
  ///
  /// All three are needed. Opacity hides it, hit testing stops a touch, and
  /// `disabled` plus `accessibilityHidden` stop an assistive technology
  /// activating a control nobody can see. The trailing toolbar control can be
  /// Start, which transmits on one tap with no confirmation step.
  fileprivate func hiddenWhileDimmed(_ dimmed: Bool) -> some View {
    opacity(dimmed ? 0 : 1)
      .allowsHitTesting(!dimmed)
      .disabled(dimmed)
      .accessibilityHidden(dimmed)
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

#if DEBUG
/// Wrist-raise timings, written to a file rather than only to the system log.
///
/// Two failures pushed this out of `NSLog` alone. `log collect --device-udid`
/// **cannot reach an Apple Watch** — the watch connects over `localNetwork` and
/// that path wants a USB-attached device, so it fails with `Device not
/// configured (6)`. Console.app can stream it, but only live, so a run is lost
/// if streaming was not already started, and the operator has to copy text back
/// by hand. A file survives the app being suspended, terminated and relaunched,
/// and comes back whole:
///
///     xcrun devicectl device copy from --device <id> \
///       --domain-type appDataContainer \
///       --domain-identifier dev.agessaman.meshmapper.watchkitapp \
///       --source Documents/wake-timings.log --destination .
///
/// Lines still go to `NSLog` as well, so Console.app keeps working for anyone
/// who prefers watching it live.
enum WakeLog {
  private static let name = "wake-timings.log"

  private static var url: URL? {
    FileManager.default
      .urls(for: .documentDirectory, in: .userDomainMask)
      .first?
      .appendingPathComponent(name)
  }

  /// Appends one timestamped line. Opened and closed per write on purpose: a
  /// held handle would not be flushed if watchOS killed the app mid-test, which
  /// is the one moment this log exists to describe.
  static func note(_ message: String) {
    guard WatchSettings.debugLogsWakeTiming else { return }
    let stamp = Date().timeIntervalSince1970
    NSLog("[wake-log] %@ at %f", message, stamp)

    guard let url else { return }
    let line = String(format: "%.4f %@\n", stamp, message)
    guard let data = line.data(using: .utf8) else { return }

    if let handle = try? FileHandle(forWritingTo: url) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: url)
    }
  }
}
#endif
