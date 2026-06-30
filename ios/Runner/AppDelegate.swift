import Flutter
import MapLibre
import UIKit
import flutter_background_service_ios

/// URLProtocol that fails fast for MapLibre tile/style/glyph/sprite requests
/// while iOS offline-map mode is engaged. MapLibre-iOS reacts to the failure
/// by serving whatever it has in its internal tile cache (downloaded offline
/// regions + opportunistically cached tiles) and renders everything else as
/// the style's background layer, which matches Android's setOffline(true)
/// behavior closely enough for the "Use Downloaded Tiles Only" toggle.
///
/// Hosts are kept in sync with the map style URLs in map_widget.dart's
/// MapStyleExtension.styleUrl (tiles.openfreemap.org) and the inline satellite
/// style JSON (server.arcgisonline.com). The coverage overlay uses per-zone
/// subdomains of meshmapper.net (e.g. `on.meshmapper.net`, `qc.meshmapper.net`)
/// so it's matched by suffix rather than an exact host entry. The Dart-side
/// add-time guard in _addCoverageOverlay covers the "toggle on at startup"
/// case; this suffix match covers the "toggle flipped while overlay is
/// already on the map" case (the Dart code doesn't remove the layer on flip).
class TileBlockingURLProtocol: URLProtocol {
  static let blockedHosts: Set<String> = [
    "tiles.openfreemap.org",
    "server.arcgisonline.com",
  ]

  static let blockedHostSuffixes: [String] = [
    ".meshmapper.net",
  ]

  override class func canInit(with request: URLRequest) -> Bool {
    guard let host = request.url?.host else { return false }
    if blockedHosts.contains(host) { return true }
    return blockedHostSuffixes.contains { host.hasSuffix($0) }
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    return request
  }

  override func startLoading() {
    let error = NSError(
      domain: NSURLErrorDomain,
      code: NSURLErrorNotConnectedToInternet,
      userInfo: [NSLocalizedDescriptionKey: "Offline map mode active"]
    )
    client?.urlProtocol(self, didFailWithError: error)
  }

  override func stopLoading() {}
}

class IOSMapOfflineBridge {
  private var registered = false

  func setOffline(_ offline: Bool) {
    if offline, !registered {
      URLProtocol.registerClass(TileBlockingURLProtocol.self)
      registered = true
    } else if !offline, registered {
      URLProtocol.unregisterClass(TileBlockingURLProtocol.self)
      registered = false
    }
  }
}

@main
@objc class AppDelegate: FlutterAppDelegate {
  private let mapOfflineBridge = IOSMapOfflineBridge()

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Register for background refresh to keep wardriving active
    if #available(iOS 13.0, *) {
      // Background processing is handled by flutter_background_service
      // The package registers its own background tasks
    }

    GeneratedPluginRegistrant.register(with: self)

    // Register background service
    SwiftFlutterBackgroundServicePlugin.taskIdentifier = "net.meshmapper.app.background"

    if let controller = window?.rootViewController as? FlutterViewController {
      // Method channel: iOS map offline mode bridge. Dart calls
      // `setOffline` from map_widget.dart to toggle the URLProtocol
      // interceptor that forces tile requests to fail fast, letting
      // MapLibre-iOS serve only cached/downloaded tiles.
      let offlineChannel = FlutterMethodChannel(
        name: "meshmapper/ios_map_offline",
        binaryMessenger: controller.binaryMessenger
      )
      offlineChannel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(FlutterError(code: "unavailable", message: "bridge deallocated", details: nil))
          return
        }
        switch call.method {
        case "setOffline":
          let args = call.arguments as? [String: Any]
          let offline = args?["offline"] as? Bool ?? false
          self.mapOfflineBridge.setOffline(offline)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      // Method channel: MapLibre tile cache management. Mirrors the Android
      // handler in MainActivity.kt. Dart's TileCacheService calls into these
      // from the Offline Maps screen's Tile Cache card.
      let tileCacheChannel = FlutterMethodChannel(
        name: "meshmapper/tile_cache",
        binaryMessenger: controller.binaryMessenger
      )
      tileCacheChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "getCacheSize":
          result(AppDelegate.mapCacheSizeBytes())
        case "getRegionSizes":
          AppDelegate.regionSizes(result: result)
        case "clearAmbientCache":
          MLNOfflineStorage.shared.clearAmbientCache { error in
            if let error = error {
              result(FlutterError(
                code: "clear_failed",
                message: error.localizedDescription,
                details: nil))
            } else {
              result(nil)
            }
          }
        case "invalidateAmbientCache":
          MLNOfflineStorage.shared.invalidateAmbientCache { error in
            if let error = error {
              result(FlutterError(
                code: "invalidate_failed",
                message: error.localizedDescription,
                details: nil))
            } else {
              result(nil)
            }
          }
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// Per-region downloaded byte counts, keyed by the Dart-side region ID that
  /// maplibre_gl embeds in each pack's context JSON (`{"id": Int, "metadata": …}`
  /// — see OfflineRegion.swift in the maplibre_gl plugin). Reads
  /// `pack.progress.countOfTileBytesCompleted`, which is the byte size of tile
  /// resources (style/sprite/glyph resources live outside this number but are
  /// included in the overall cache.db file total reported by `getCacheSize`).
  ///
  /// Returns `{ idInt64 : bytesInt64 }` over the platform channel. Packs whose
  /// context can't be decoded are skipped.
  private static func regionSizes(result: @escaping FlutterResult) {
    // `.packs` is nil until MLNOfflineStorage finishes its initial database
    // load. In practice the maplibre_gl plugin forces that load early, but we
    // return an empty map rather than failing if we're called first.
    guard let packs = MLNOfflineStorage.shared.packs else {
      result([Int64: Int64]())
      return
    }
    var sizes: [Int64: Int64] = [:]
    for pack in packs {
      guard let ctx = try? JSONSerialization.jsonObject(with: pack.context),
            let dict = ctx as? [String: Any],
            let id = dict["id"] as? Int else {
        continue
      }
      sizes[Int64(id)] = Int64(pack.progress.countOfTileBytesCompleted)
    }
    result(sizes)
  }

  /// Mirrors `MapLibreMapsPlugin.getTilesUrl()`: the maplibre_gl iOS plugin
  /// stores its tile cache at `<appSupport>/<bundleId>/.mapbox/cache.db`.
  /// Returns 0 if the file doesn't exist.
  private static func mapCacheSizeBytes() -> Int64 {
    guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask).first,
          let bundleId = Bundle.main.bundleIdentifier else {
      return 0
    }
    let cacheUrl = appSupport
      .appendingPathComponent(bundleId)
      .appendingPathComponent(".mapbox")
      .appendingPathComponent("cache.db")
    let attrs = try? FileManager.default.attributesOfItem(atPath: cacheUrl.path)
    return (attrs?[.size] as? Int64) ?? 0
  }
}
