import 'package:shared_preferences/shared_preferences.dart';

/// Whether the person has agreed to the location disclosure on this install.
/// Google Play wants it agreed before the app reads any location, and shown
/// again right before every system location prompt.
///
/// Kept apart from the dialog (`PermissionDisclosureService`) so GpsService
/// can check it without importing UI code.
class LocationConsent {
  LocationConsent._();

  /// Set when the person taps Agree. The key predates the Agree button, so
  /// Continue on the old dialog counts as agreeing.
  static const String _agreedKey = 'location_disclosure_shown';

  /// True once the location disclosure has been agreed to. Until then the
  /// app reads no location, even when the permission is already granted
  /// (review devices can install with it granted).
  static Future<bool> hasAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_agreedKey) ?? false;
  }

  static Future<void> markAgreed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_agreedKey, true);
  }

  /// Whether the disclosure must come up now: always before a system prompt,
  /// and until it has been agreed to even when no prompt is next.
  static bool needsDisclosure({
    required bool agreed,
    required bool aboutToRequest,
  }) =>
      !agreed || aboutToRequest;
}
