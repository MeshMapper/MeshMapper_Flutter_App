import Flutter
import UIKit

/// Flutter's UIScene host. Required by iOS 27, which no longer permits apps
/// linked against the current SDK to rely on the legacy AppDelegate window.
class SceneDelegate: FlutterSceneDelegate {
  // This app restores its session from its own stores. Avoid Flutter's scene
  // restoration NSUserActivity, which aborts on this iOS build when backgrounded.
  override func stateRestorationActivity(for scene: UIScene) -> NSUserActivity? {
    return nil
  }
}
