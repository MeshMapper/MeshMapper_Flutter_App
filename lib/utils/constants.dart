/// Application constants
class AppConstants {
  AppConstants._();

  /// Application version
  /// Set at build time via --dart-define=APP_VERSION=APP-<epoch>
  /// Falls back to runtime epoch if not set
  static const String _buildVersion = String.fromEnvironment(
    'APP_VERSION',
    defaultValue: '',
  );

  static final String appVersion = _buildVersion.isNotEmpty
      ? _buildVersion
      : 'APP-${DateTime.now().millisecondsSinceEpoch ~/ 1000}';

  /// Returns true if the app version is a development build (EPOCH format)
  /// Development builds: APP-<unix_epoch_seconds> (e.g., APP-1705273849) - digits only
  /// Release builds: APP-<x.y.z> (e.g., APP-1.2.3) - contains dots
  static bool get isDevelopmentBuild {
    // EPOCH format: APP- followed by digits only (no dots)
    // Release format: APP- followed by semantic version with dots (e.g., APP-1.2.3)
    final epochPattern = RegExp(r'^APP-\d+$');
    return epochPattern.hasMatch(appVersion);
  }

  /// Application name
  static const String appName = 'MeshMapper';

  /// User agent string for API calls
  static String get userAgent => '$appName/$appVersion Flutter';
}
