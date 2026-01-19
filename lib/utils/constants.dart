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

  /// Application name
  static const String appName = 'MeshMapper';

  /// User agent string for API calls
  static String get userAgent => '$appName/$appVersion Flutter';
}
