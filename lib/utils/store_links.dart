import 'package:flutter/foundation.dart';

/// Where the "update the app" button sends the user, and what it says.
@immutable
class StoreLink {
  final Uri uri;
  final String label;

  const StoreLink(this.uri, this.label);

  @override
  bool operator ==(Object other) =>
      other is StoreLink && other.uri == uri && other.label == label;

  @override
  int get hashCode => Object.hash(uri, label);

  @override
  String toString() => 'StoreLink($label, $uri)';
}

/// Picks the update link from how the app was installed.
///
/// `installerStore` is `PackageInfo.installerStore`: on iOS the plugin reads
/// the receipt path (`com.apple.testflight` for TestFlight, `com.apple` for
/// the App Store, `com.apple.simulator`), on Android it is the installer
/// package name. Play shows closed-test members the testing build on the
/// normal listing, so one Play link covers testers and production.
class StoreLinks {
  StoreLinks._();

  static const String appleAppId = '6758073991';
  static const String androidPackage = 'net.meshmapper.app';

  static final StoreLink testFlight = StoreLink(
    Uri.parse('itms-beta://beta.itunes.apple.com/v1/app/$appleAppId'),
    'Update in TestFlight',
  );
  static final StoreLink appStore = StoreLink(
    Uri.parse('https://apps.apple.com/app/id$appleAppId'),
    'Update MeshMapper',
  );
  static final StoreLink playStore = StoreLink(
    Uri.parse(
        'https://play.google.com/store/apps/details?id=$androidPackage'),
    'Update MeshMapper',
  );
  static final StoreLink githubRelease = StoreLink(
    Uri.parse(
        'https://github.com/MeshMapper/MeshMapper_Project/releases/latest'),
    'Download latest version',
  );

  static const Set<String> _playInstallers = {
    'com.android.vending',
    'com.google.android.feedback',
  };

  static StoreLink resolve(TargetPlatform platform, String? installerStore) {
    switch (platform) {
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return installerStore == 'com.apple.testflight' ? testFlight : appStore;
      case TargetPlatform.android:
        return _playInstallers.contains(installerStore)
            ? playStore
            : githubRelease;
      default:
        return githubRelease;
    }
  }
}

/// What the "Update MeshMapper to continue" panel shows after the server
/// refused this build (`/auth` reason `outofdate`).
@immutable
class AppUpdateRequirement {
  /// The connection error text this requirement belongs to. The panel only
  /// shows while this is still the current connection error.
  final String errorMessage;

  /// One small line, e.g. "Your version: 1.3.0 · Needed: 1.4.0".
  final String versionLine;

  final StoreLink link;

  const AppUpdateRequirement({
    required this.errorMessage,
    required this.versionLine,
    required this.link,
  });
}

/// The minimum the server named in its `outofdate` message, e.g.
/// "App version outdated. Required: v1.4.0" or
/// "Dev version outdated. Required: 1791170991". Null when it names none.
String? parseRequiredAppVersion(String? serverMessage) {
  if (serverMessage == null) return null;
  final match =
      RegExp(r'Required:\s*v?([0-9][0-9A-Za-z.\-]*)').firstMatch(serverMessage);
  final version = match?.group(1);
  if (version == null) return null;
  // A trailing sentence full stop is not part of the version.
  return version.endsWith('.')
      ? version.substring(0, version.length - 1)
      : version;
}

/// "Your version: 1.3.0 · Needed: 1.4.0" for a store build, or
/// "Your build: 1790996175 · Needed: 1791170991" for a TestFlight build,
/// which the server compares by build number. `appVersion` is the
/// `APP-<x.y.z>` or `APP-<epoch>` string sent to the server.
String appUpdateVersionLine(String appVersion, String? requiredVersion) {
  final own = appVersion.startsWith('APP-') ? appVersion.substring(4) : appVersion;
  final isBuild = RegExp(r'^\d+$').hasMatch(own);
  final ownLine = isBuild ? 'Your build: $own' : 'Your version: $own';
  if (requiredVersion == null || requiredVersion.isEmpty) return ownLine;
  return '$ownLine · Needed: $requiredVersion';
}
