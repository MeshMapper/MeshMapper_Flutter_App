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
    static let mainPageContent = "layout.mainPageContent"
    static let nodeListPlacement = "layout.nodeListPlacement"
    static let defaultStartMode = "controls.defaultStartMode"
    static let showPingWhenAvailable = "controls.showPingWhenAvailable"
  }

  /// Roughly 250 m north-south: one degree of latitude is about 111,320 m.
  static let defaultMapLatitudeDelta = 0.00225
  private static let mapLatitudeDeltaLimits = 0.0005...0.5
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
