import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../providers/app_state_provider.dart';
import '../services/permission_disclosure_service.dart';

Future<bool> setUpBackgroundLocation(
  BuildContext context,
  AppStateProvider appState,
) async {
  final accepted =
      await PermissionDisclosureService.showBackgroundLocationDisclosure(
    context,
  );
  if (!accepted || !context.mounted) return false;

  final granted = await appState.requestAlwaysLocationPermission();
  if (granted || !context.mounted) return granted;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Permission Required'),
      content: const Text(
        'To enable background location tracking, open Settings and set '
        'Location to "Always".\n\nThis allows MeshMapper to track your '
        'location in the background during continuous wardriving.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('Not Now'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(dialogContext);
            Geolocator.openAppSettings();
          },
          child: const Text('Open Settings'),
        ),
      ],
    ),
  );
  return false;
}
