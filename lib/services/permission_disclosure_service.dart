import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'location_consent.dart';

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

  /// The lead follows Google Play's wording for a location disclosure: the
  /// word "location" and every feature that uses it, plus when each one runs.
  /// Background use only happens while a radio is connected, so it says that
  /// instead of "even when the app is closed or not in use".
  static const String locationDisclosureLead =
      'MeshMapper collects and uses location data while the app is open, to '
      'show you on the map and check which region you are in. While it is '
      'connected to your radio, it also uses location to keep the radio '
      'signed in and, while a wardriving mode runs, to tag your pings and map '
      'coverage, including with the screen off or another app open. When you '
      'disconnect and leave the app, MeshMapper stops using your location.';

  /// The iOS "Always" dialog's lead.
  static const String backgroundDisclosureLead =
      'MeshMapper collects location data in the background only while your '
      'radio is connected, to keep tagging pings and mapping coverage during '
      'a wardriving mode. When you disconnect, it stops.';

  /// Android only: the foreground service's notification is the visible sign
  /// that location is in use with the app out of sight.
  static const String androidNotificationPoint =
      'A notification shows while your radio is connected.';

  /// Where location leaves the phone, shown in both dialogs.
  static const List<String> sharingPoints = [
    'While a mode is running, your pings are uploaded with their locations '
        'to meshmapper.net and shown on public coverage maps.',
    'If you turn on Broadcast My Coordinates, your pings also carry your '
        'location over the mesh radio.',
    'If you set up a Custom API Endpoint, your uploaded pings are also sent '
        'there.',
    'Debug logs you choose to send include your recent locations.',
  ];

  /// The region check (`/status`), the connect `/auth` and the heartbeat:
  /// the server checks the fix and stores only the region.
  static const String noModePoint =
      'With no mode running, your location is only sent to meshmapper.net to '
      'check your region and keep a connected radio signed in. The location '
      'itself is not saved.';

  /// Show the prominent disclosure. Google Play wants it before the app first
  /// reads location and right before every system location prompt; callers
  /// go on only when this returns true (Agree), which is also remembered.
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
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                locationDisclosureLead,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              const _SharingHeading(),
              _BulletPoint(text: sharingPoints.first),
              const _BulletPoint(text: noModePoint),
              for (final point in sharingPoints.skip(1))
                _BulletPoint(text: point),
              if (defaultTargetPlatform == TargetPlatform.android)
                const _BulletPoint(text: androidNotificationPoint),
              const SizedBox(height: 16),
              const Text(
                'Offline Mode keeps your pings on this phone until you choose '
                'to upload them.',
                style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: _agreeActions(context),
      ),
    );

    final agreed = result ?? false;
    if (agreed) await LocationConsent.markAgreed();
    return agreed;
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
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                backgroundDisclosureLead,
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 16),
              const _SharingHeading(),
              for (final point in sharingPoints) _BulletPoint(text: point),
              const SizedBox(height: 12),
              const Text(
                'This allows location access all the time. You can turn it '
                'off in your device\'s Settings.',
                style: TextStyle(fontSize: 14),
              ),
            ],
          ),
        ),
        actions: _agreeActions(context),
      ),
    );

    return result ?? false;
  }

  static List<Widget> _agreeActions(BuildContext context) => [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not Now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Agree'),
        ),
      ];
}

class _SharingHeading extends StatelessWidget {
  const _SharingHeading();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(bottom: 8),
      child: Text(
        'How your location is used and shared',
        style: TextStyle(fontWeight: FontWeight.w600),
      ),
    );
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
