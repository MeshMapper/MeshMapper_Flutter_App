import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import '../models/connection_state.dart';
import '../providers/app_state_provider.dart';
import '../services/location_consent.dart';
import '../services/permission_disclosure_service.dart';

Future<bool> setUpBackgroundLocation(
  BuildContext context,
  AppStateProvider appState,
) async {
  // The background dialog only covers background use, so the main location
  // disclosure comes first until it has been agreed to.
  if (!await LocationConsent.hasAgreed()) {
    if (!context.mounted) return false;
    final agreed =
        await PermissionDisclosureService.showLocationDisclosure(context);
    if (!agreed) return false;
  }
  if (!context.mounted) return false;

  final accepted =
      await PermissionDisclosureService.showBackgroundLocationDisclosure(
    context,
  );
  if (!accepted || !context.mounted) return false;

  final granted = await appState.requestAlwaysLocationPermission();
  // This may be the first grant or the first Agree, and GPS refuses to
  // start before both. Only when it is off: a restart mid-mode would reset
  // the airborne latch and altitude tracking.
  if (appState.gpsStatus == GpsStatus.permissionDenied) {
    await appState.restartGpsAfterPermission();
  }
  if (granted || !context.mounted) return granted;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Permission Required'),
      content: const Text(
        'To keep using your location in the background while your radio is '
        'connected, open Settings and set Location to "Always".',
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
