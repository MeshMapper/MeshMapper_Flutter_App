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
    static let nodeListPlacement = "layout.nodeListPlacement"
  }

  /// Where the recently-responded list lives.
  ///
  /// Both layouts are built from one view model, so this is a presentation
  /// toggle rather than two code paths. The default is unsettled until it has
  /// been worn — see the plan.
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

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    satellite = defaults.bool(forKey: Key.satellite)
    showLinks = defaults.bool(forKey: Key.showLinks)
    // Following the fix is the useful default while driving; absent any
    // stored value `bool(forKey:)` returns false, so invert an explicit flag.
    follow = defaults.object(forKey: Key.follow) as? Bool ?? true
    nodeListPlacement = (defaults.string(forKey: Key.nodeListPlacement))
      .flatMap(NodeListPlacement.init(rawValue:)) ?? .sheet
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

  var nodeListPlacement: NodeListPlacement {
    didSet { defaults.set(nodeListPlacement.rawValue, forKey: Key.nodeListPlacement) }
  }
}

extension Color {
  /// Colours arrive already resolved from the phone's colour-vision palette,
  /// so the watch never needs to know which palette is active.
  init(_ watchColor: WatchColor) {
    self.init(red: watchColor.r, green: watchColor.g, blue: watchColor.b)
  }
}
