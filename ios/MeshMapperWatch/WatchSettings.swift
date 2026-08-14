import CoreLocation
import Foundation
import SwiftUI

/// Wrist-side preferences.
///
/// These are watch-local on purpose: they describe how this small screen is
/// laid out, not anything about the mapping session, so syncing them from the
/// phone would add a round-trip for no benefit.
@Observable
final class WatchSettings {
  private enum Key {
    static let satellite = "map.satellite"
    static let showLinks = "map.showLinks"
    static let follow = "map.follow"
    static let mapLatitudeDelta = "map.latitudeDelta"
    static let mapZoomDefaultsVersion = "map.zoomDefaultsVersion"
    static let mapLastCenter = "map.lastCenter"
    static let mainPageContent = "layout.mainPageContent"
    static let nodeListPlacement = "layout.nodeListPlacement"
    static let defaultStartMode = "controls.defaultStartMode"
    static let showPingWhenAvailable = "controls.showPingWhenAvailable"
  }

  /// Roughly 250 m north-south: one degree of latitude is about 111,320 m.
  static let defaultMapLatitudeDelta = 0.00225
  /// The Crown's own range is wider than this at both ends, and the two bounds
  /// are set for different reasons.
  ///
  /// **The floor tracks the hardware.** Measured on a Series 9, MapKit's
  /// tightest Crown zoom is about 0.000230 degrees (~26 m); the floor used to
  /// be 0.0005 (~56 m), so zooming in past that was clamped and the next
  /// re-assert snapped the map back out. The wearer reported it as the map not
  /// holding position. 0.0002 sits just below the observed limit so the Crown
  /// is never fought on the way in.
  ///
  /// **The ceiling is a policy, not a measurement.** The Crown reaches about
  /// 25 degrees (~2,800 km), and persisting that would let the app open showing
  /// a continent — visually indistinguishable from the `.automatic` bug this
  /// file exists to prevent, just chosen rather than inflicted. 0.5 (~56 km)
  /// keeps a stray flick from becoming a sticky state. Zooming out past it
  /// still works; only the persisted value is capped.
  private static let mapLatitudeDeltaLimits = 0.0002...0.5
  private static let mapZoomDefaultsVersion = 1

  /// Where the recently-responded list lives.
  ///
  /// Both layouts are built from one view model, so this is a presentation
  /// toggle rather than two code paths. Its own page is the default — chosen
  /// for the room it gives the rows — and the sheet stays for wearers who would
  /// rather keep the map behind the list.
  enum NodeListPlacement: String, CaseIterable, Identifiable {
    case sheet
    case page

    var id: String { rawValue }

    var label: String {
      switch self {
      case .sheet: return "Sheet over map"
      case .page: return "Its own page"
      }
    }
  }

  /// What occupies the app's first page at full luminance.
  ///
  /// Reduced luminance remains a separate system condition: either choice can
  /// still enter the power-frugal readout when the wrist drops.
  enum MainPageContent: String, CaseIterable, Identifiable {
    case map
    case readout

    var id: String { rawValue }

    var label: String {
      switch self {
      case .map: return "Map"
      case .readout: return "Readout"
      }
    }
  }

  /// The explicit mode a wrist Start will request. The phone remains the final
  /// authority and can refuse Hybrid if zone policy changed after the snapshot.
  enum DefaultStartMode: String, CaseIterable, Identifiable {
    case passive
    case hybrid

    var id: String { rawValue }

    var label: String {
      switch self {
      case .passive: return "Passive"
      case .hybrid: return "Hybrid"
      }
    }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    satellite = defaults.bool(forKey: Key.satellite)
    showLinks = defaults.bool(forKey: Key.showLinks)
    // Following the fix is the useful default while driving; absent any
    // stored value `bool(forKey:)` returns false, so invert an explicit flag.
    follow = defaults.object(forKey: Key.follow) as? Bool ?? true
    // Rendered MapKit spans drift from the region requested, so an equality
    // test cannot identify the old default reliably. A versioned migration
    // deliberately resets every existing install once; after recording the
    // version, ordinary Crown write-back owns the value again.
    if defaults.integer(forKey: Key.mapZoomDefaultsVersion) < Self.mapZoomDefaultsVersion {
      mapLatitudeDelta = Self.defaultMapLatitudeDelta
      defaults.set(Self.defaultMapLatitudeDelta, forKey: Key.mapLatitudeDelta)
      defaults.set(Self.mapZoomDefaultsVersion, forKey: Key.mapZoomDefaultsVersion)
    } else {
      // `double(forKey:)` turns absence into zero, which would silently select
      // the minimum zoom. Preserve the distinction so an absent value gets the
      // deliberate ~250 m default instead.
      mapLatitudeDelta = Self.clampedMapLatitudeDelta(
        defaults.object(forKey: Key.mapLatitudeDelta) as? Double
          ?? Self.defaultMapLatitudeDelta
      )
    }
    mainPageContent = (defaults.string(forKey: Key.mainPageContent))
      .flatMap(MainPageContent.init(rawValue:)) ?? .map
    nodeListPlacement = (defaults.string(forKey: Key.nodeListPlacement))
      .flatMap(NodeListPlacement.init(rawValue:)) ?? .page
    defaultStartMode = (defaults.string(forKey: Key.defaultStartMode))
      .flatMap(DefaultStartMode.init(rawValue:)) ?? .passive
    showPingWhenAvailable = defaults.object(
      forKey: Key.showPingWhenAvailable
    ) as? Bool ?? false
  }

  /// Apple imagery rather than the standard basemap. Mirrors the iOS app's
  /// satellite option, though the imagery is Apple's, not ArcGIS.
  var satellite: Bool {
    didSet { defaults.set(satellite, forKey: Key.satellite) }
  }

  /// Draw a line from the fix to each repeater that answered the last ping.
  var showLinks: Bool {
    didSet { defaults.set(showLinks, forKey: Key.showLinks) }
  }

  /// Keep the camera on the phone's position.
  var follow: Bool {
    didSet { defaults.set(follow, forKey: Key.follow) }
  }

  /// Only latitude is persisted. MapKit fits longitude to the watch's aspect
  /// ratio, so storing both would preserve two values that are not independent.
  /// Normalising before persistence keeps a bad Crown result from becoming a
  /// sticky launch state.
  var mapLatitudeDelta: Double {
    didSet {
      let clamped = Self.clampedMapLatitudeDelta(mapLatitudeDelta)
      if clamped != mapLatitudeDelta {
        mapLatitudeDelta = clamped
      }
      // Persist the normalised value explicitly rather than relying on an
      // assignment inside `didSet` to invoke the observer a second time.
      defaults.set(clamped, forKey: Key.mapLatitudeDelta)
    }
  }

  /// Where the camera last rested, so a map with no live fix opens on the last
  /// place the wearer actually saw rather than on MapKit's annotation fit.
  ///
  /// `.automatic` is not a neutral starting state: measured on a Series 9 it
  /// renders 34.4 degrees of latitude, about 3,800 km, and once the camera
  /// lands there nothing in `MapPage` moves it back. This value is the seed
  /// that keeps that from being reachable — see `anchorCameraIfNeeded`.
  ///
  /// Deliberately *not* `@Observable`-backed state: nothing renders from it, it
  /// is read once per native-map lifetime, and making it observable would
  /// invalidate the map on every GPS step it records.
  ///
  /// Absence is distinguished from zero the same way the span is. `0, 0` is a
  /// real coordinate in the Gulf of Guinea, so treating a missing key as zero
  /// would open a fresh install in the Atlantic rather than falling through to
  /// the live fix.
  ///
  /// Stored as one array rather than a latitude key, a longitude key and a
  /// timestamp key. Separate writes can be torn apart by the app being killed
  /// between them — watchOS terminates this app freely, which is the whole
  /// reason the value is persisted — and half a coordinate is a
  /// plausible-looking centre somewhere on the equator or the prime meridian.
  /// One key cannot tear.
  var lastMapCenter: CLLocationCoordinate2D? {
    storedMapCenter?.center
  }

  /// The stored centre only while it still plausibly describes where the wearer
  /// is, which is what lets a live fix outrank it.
  ///
  /// Without an age, a centre saved in another city wins over a real fix
  /// forever once Follow is off. That matters more here than it would on the
  /// phone, because `interactionModes` is `[.zoom]` — the wearer cannot pan out
  /// of a wrong place, only zoom within it.
  ///
  /// Twelve hours is chosen to survive a full session and a break, while not
  /// surviving a night's travel. Note that a fresh centre and a live fix agree
  /// whenever the wearer has not moved, so this threshold only decides the case
  /// where they *have* — which is exactly the case the live fix answers better.
  var freshMapCenter: CLLocationCoordinate2D? {
    guard let stored = storedMapCenter,
      let savedAt = stored.savedAt,
      Date().timeIntervalSince1970 - savedAt < Self.mapCenterFreshnessSeconds
    else { return nil }
    return stored.center
  }

  private static let mapCenterFreshnessSeconds: TimeInterval = 12 * 60 * 60

  /// A missing timestamp is treated as unknown age rather than as fresh, so an
  /// older two-element value can never masquerade as current.
  private var storedMapCenter: (center: CLLocationCoordinate2D, savedAt: TimeInterval?)? {
    guard
      let stored = defaults.array(forKey: Key.mapLastCenter) as? [Double],
      stored.count >= 2
    else { return nil }
    let (lat, lon) = (stored[0], stored[1])
    guard
      lat.isFinite, lon.isFinite,
      (-90...90).contains(lat), (-180...180).contains(lon)
    else { return nil }
    let savedAt = stored.count >= 3 && stored[2].isFinite ? stored[2] : nil
    return (CLLocationCoordinate2D(latitude: lat, longitude: lon), savedAt)
  }

  /// Record a centre the camera was actually driven to.
  ///
  /// Throttled because follow asserts a region on every geo update, and the
  /// phone's own `minMoveMeters` filter (15 m) is *finer* than anything this
  /// value needs — left unthrottled at walking pace this would write roughly
  /// once every 11 seconds for the life of a session, against active battery
  /// work.
  ///
  /// A coarse threshold is affordable because this is only ever read at app
  /// launch: within a session `MapPage` holds the live centre in memory and
  /// never consults this. So the stored value only has to be good enough to
  /// open the map in the right place, and it is competing against `.automatic`
  /// at 3,800 km — not against a perfect restore.
  func noteMapCenter(_ center: CLLocationCoordinate2D) {
    guard
      center.latitude.isFinite, center.longitude.isFinite,
      (-90...90).contains(center.latitude),
      (-180...180).contains(center.longitude)
    else { return }

    // Freshness is part of the skip test, not just position. A wearer who stays
    // put would otherwise match the stored coordinates forever, never rewrite
    // the entry, and so let its timestamp expire under an accurate centre —
    // the map would then decline to use a position that never stopped being
    // correct. Requiring freshness here costs one write per expiry window.
    if let stored = lastMapCenter, freshMapCenter != nil,
      abs(stored.latitude - center.latitude) < Self.mapCenterWriteThreshold,
      abs(stored.longitude - center.longitude) < Self.mapCenterWriteThreshold
    {
      return
    }
    defaults.set(
      [center.latitude, center.longitude, Date().timeIntervalSince1970],
      forKey: Key.mapLastCenter
    )
  }

  /// About 110 m of latitude. Degrees, not metres: longitude convergence is
  /// irrelevant to a write throttle, and treating it as a distance would imply
  /// a precision this value does not need.
  private static let mapCenterWriteThreshold = 0.001

  var mainPageContent: MainPageContent {
    didSet { defaults.set(mainPageContent.rawValue, forKey: Key.mainPageContent) }
  }

  var nodeListPlacement: NodeListPlacement {
    didSet { defaults.set(nodeListPlacement.rawValue, forKey: Key.nodeListPlacement) }
  }

  var defaultStartMode: DefaultStartMode {
    didSet { defaults.set(defaultStartMode.rawValue, forKey: Key.defaultStartMode) }
  }

  var showPingWhenAvailable: Bool {
    didSet { defaults.set(showPingWhenAvailable, forKey: Key.showPingWhenAvailable) }
  }

  #if DEBUG
  /// Freeze the countdown bar's drain, for measuring what that animation costs.
  ///
  /// Read statically rather than through an instance so the animation path does
  /// not take an observation dependency on it: flipping this must change the
  /// next phase, not invalidate the view mid-drain and perturb the very trace
  /// it exists to produce.
  static var debugFreezesTimerBar: Bool {
    UserDefaults.standard.bool(forKey: "MeshMapperFreezeTimerBar")
  }

  var freezesTimerBar: Bool {
    get { Self.debugFreezesTimerBar }
    set { defaults.set(newValue, forKey: "MeshMapperFreezeTimerBar") }
  }

  /// Record wrist-raise timings to `WakeLog`.
  ///
  /// **Persisted deliberately, and this is the whole point.** The same job was
  /// first done by a `-MeshMapperTimeSwitchToMap` launch argument, which cannot
  /// work here: launch arguments live in `NSArgumentDomain` and evaporate the
  /// moment watchOS terminates and relaunches the app — which is exactly what a
  /// wrist-down test provokes. The gate closed silently and the run produced an
  /// empty log with nothing to indicate why. A measurement switch that outlives
  /// process death has to be persisted, and being on the wrist means it can be
  /// flipped without a reinstall.
  static var debugLogsWakeTiming: Bool {
    UserDefaults.standard.bool(forKey: "MeshMapperLogWakeTiming")
      || UserDefaults.standard.bool(forKey: "MeshMapperTimeSwitchToMap")
  }

  var logsWakeTiming: Bool {
    get { Self.debugLogsWakeTiming }
    set { defaults.set(newValue, forKey: "MeshMapperLogWakeTiming") }
  }
  #endif

  /// One promise shared by Settings and the explicit-mode Start control. If
  /// these surfaces resolve independently, Settings can claim Hybrid while a
  /// tap silently requests Passive — precisely the kind of mode ambiguity the
  /// explicit command field exists to prevent.
  func effectiveStartMode(
    availableStartModes: [String]?
  ) -> DefaultStartMode {
    let advertised = availableStartModes ?? [DefaultStartMode.passive.rawValue]
    return advertised.contains(defaultStartMode.rawValue)
      ? defaultStartMode
      : .passive
  }

  private static func clampedMapLatitudeDelta(_ value: Double) -> Double {
    guard value.isFinite else { return defaultMapLatitudeDelta }
    return min(max(value, mapLatitudeDeltaLimits.lowerBound), mapLatitudeDeltaLimits.upperBound)
  }
}

/// Shared control chrome, lifted from the phone rather than accumulating
/// unrelated system tints across wrist surfaces. Ping and repeater data colours
/// are different: those arrive resolved through the phone's colour-vision
/// palette, while these action semantics remain fixed just as today's red and
/// green buttons do. Revisit this boundary if watch controls become palette-aware.
enum WatchPalette {
  static let start = Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
  static let stop = Color(red: 189 / 255, green: 33 / 255, blue: 48 / 255)
  static let ping = Color(red: 99 / 255, green: 102 / 255, blue: 241 / 255)
  static let armed = Color(red: 245 / 255, green: 158 / 255, blue: 11 / 255)
  static let disabled = Color(red: 51 / 255, green: 65 / 255, blue: 85 / 255)
  static let secondary = Color(red: 71 / 255, green: 85 / 255, blue: 105 / 255)
  static let tertiary = Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255)
  static let cornerRadius: CGFloat = 12
}

extension Color {
  /// Colours arrive already resolved from the phone's colour-vision palette,
  /// so the watch never needs to know which palette is active.
  init(_ watchColor: WatchColor) {
    self.init(red: watchColor.r, green: watchColor.g, blue: watchColor.b)
  }
}
