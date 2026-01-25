import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Service to handle Google Play prominent disclosure requirements
/// Shows a disclosure dialog before requesting sensitive permissions
class PermissionDisclosureService {
  static const String _disclosureShownKey = 'location_disclosure_shown';

  /// Check if the disclosure has been shown before
  static Future<bool> hasShownDisclosure() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_disclosureShownKey) ?? false;
  }

  /// Mark the disclosure as shown
  static Future<void> markDisclosureShown() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_disclosureShownKey, true);
  }

  /// Show the prominent disclosure dialog
  /// Returns true if user accepts, false if they decline
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
              child: Text('Location Access Required'),
            ),
          ],
        ),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'MeshMapper collects your location to:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 12),
              _BulletPoint(text: 'Track where you send pings on the mesh network'),
              _BulletPoint(text: 'Map coverage areas for the community'),
              _BulletPoint(text: 'Record which repeaters hear your device'),
              SizedBox(height: 16),
              Text(
                'Data Sharing',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 8),
              Text(
                'Your location data is uploaded to the MeshMapper API and displayed on public coverage maps at meshmapper.net to help the mesh radio community.',
                style: TextStyle(fontSize: 14),
              ),
              SizedBox(height: 16),
              Text(
                'You can use offline mode to store data locally without uploading.',
                style: TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Continue'),
          ),
        ],
      ),
    );

    if (result == true) {
      await markDisclosureShown();
    }

    return result ?? false;
  }

  /// Show the background location disclosure (for "Always" permission)
  /// Returns true if user accepts, false if they decline
  static Future<bool> showBackgroundLocationDisclosure(BuildContext context) async {
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
                'MeshMapper needs background location access to:',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              SizedBox(height: 12),
              _BulletPoint(text: 'Continue tracking coverage while the app is minimized'),
              _BulletPoint(text: 'Send automatic pings during extended wardriving sessions'),
              SizedBox(height: 16),
              Text(
                'This grants "always on" location access, but we only collect what\'s needed: tagging pings while wardriving and checking if you\'re in a supported zone.',
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
            child: const Text('Enable'),
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
