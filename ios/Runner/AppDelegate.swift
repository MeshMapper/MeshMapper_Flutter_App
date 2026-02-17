import Flutter
import UIKit
import flutter_background_service_ios

@main
@objc class AppDelegate: FlutterAppDelegate {
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

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }
}
