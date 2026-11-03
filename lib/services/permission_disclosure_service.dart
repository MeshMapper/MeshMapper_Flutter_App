import 'package:flutter/material.dart';

/// Service to handle Google Play prominent disclosure requirements
/// Shows a disclosure dialog before requesting sensitive permissions
class PermissionDisclosureService {
  /// A permission request that comes back denied faster than this was
  /// answered by the OS, not by a person. After two refusals Android stops
  /// showing the system dialog and (on some builds) still reports plain
  /// `denied` rather than `permanentlyDenied`, so a fast denial is the only
  /// sign that no dialog was shown and the app settings are the way forward.
  static const Duration silentDenialThreshold = Duration(milliseconds: 500);

  /// True when a request that came back still denied after [elapsed] was
  /// answered without the system dialog ever being shown.
  static bool deniedWithoutDialog(Duration elapsed) =>
      elapsed < silentDenialThreshold;

  /// The lead sentence follows Google Play's recommended wording for a
  /// location disclosure: the word "location", every feature that uses it,
  /// and "even when the app is closed or not in use". Play rejected 1.4.1
  /// for a disclosure without the background phrase.
  ///
  /// Background use is scoped to a running mode because that is when it
  /// happens: the Android service starts with a mode, and nothing is
  /// uploaded without one. With no mode, GPS only places you on the map and
  /// feeds the region check, which the server answers without storing.
  static const String locationDisclosureLead =
      'MeshMapper collects location data to tag your pings and map mesh '
      'coverage while a wardriving mode is running, even when the app is '
      'closed or not in use.';

  static const String backgroundDisclosureLead =
      'MeshMapper collects location data in the background to keep tagging '
      'pings and mapping coverage while a wardriving mode is running, even '
      'when the app is closed or not in use.';

  /// Show the prominent disclosure. Google Play wants it right before every
  /// system location prompt, so callers show it each time they are about to
  /// request, and request only when this returns true (Agree).
  static Future<bool> showLocationDisclosure(BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.location_on, color: Colors.blue),
            SizedBox(width: 12),
            Expanded(
              child: Text('Location Data'),
            ),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                locationDisclosureLead,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 16),
              Text(
                'How your location is used and shared',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              _BulletPoint(
                  text:
                      'While a mode is running, your pings are uploaded with their locations to meshmapper.net and shown on public coverage maps.'),
              _BulletPoint(
                  text:
                      'With no mode running, your location only shows you on the map and is sent to meshmapper.net to check which region you are in. The location itself is not saved.'),
              _BulletPoint(
                  text:
                      'If you turn on Broadcast My Coordinates, your pings also carry your location over the mesh radio.'),
              _BulletPoint(
                  text:
                      'If you set up a Custom API Endpoint, your uploaded pings are also sent there.'),
              SizedBox(height: 16),
              Text(
                'Offline Mode keeps your pings on this phone instead of uploading them.',
                style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Agree'),
          ),
        ],
      ),
    );

    return result ?? false;
  }

  /// Show the background location disclosure (for "Always" permission)
  /// Returns true if user accepts, false if they decline
  static Future<bool> showBackgroundLocationDisclosure(
      BuildContext context) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.location_on, color: Colors.orange),
            SizedBox(width: 12),
            Expanded(
              child: Text('Background Location'),
            ),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                backgroundDisclosureLead,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 12),
              Text(
                'Your pings are uploaded with their locations to meshmapper.net and shown on public coverage maps.',
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 12),
              Text(
                'This allows location access all the time. You can turn it off in your device\'s Settings.',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Not Now'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Agree'),
          ),
        ],
      ),
    );

    return result ?? false;
  }
}

/// Helper widget for bullet points in disclosure dialog
class _BulletPoint extends StatelessWidget {
  final String text;

  const _BulletPoint({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('• ', style: TextStyle(fontSize: 14)),
          Expanded(
            child: Text(text, style: const TextStyle(fontSize: 14)),
          ),
        ],
      ),
    );
  }
}
