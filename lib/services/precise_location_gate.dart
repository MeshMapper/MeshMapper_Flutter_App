/// The Precise Location check made when the user taps Connect.
///
/// With iOS "Precise Location" off, or Android 12+ granting only approximate
/// location, the OS hands out fixes off by hundreds of metres to kilometres.
/// The server refuses every fix worse than 50 m (`gps_inaccurate`), so such a
/// session maps nothing. The connect is refused instead, after one chance to
/// turn precise location on (iOS: the temporary full accuracy prompt; Android:
/// one fine-location re-request, which shows the "precise" upgrade dialog).
///
/// This only reads the accuracy authorisation and asks for it. It never
/// starts GPS or sends a location.
library;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import '../utils/debug_logger_io.dart';

/// Purpose key for `NSLocationTemporaryUsageDescriptionDictionary` in
/// `ios/Runner/Info.plist`. The plugin errors if the dictionary is missing.
const String preciseLocationPurposeKey = 'CoverageMapping';

/// Title of the dialog shown when a connect is refused.
const String preciseLocationDialogTitle = 'Precise Location needed';

/// Body of the dialog shown when a connect is refused.
const String preciseLocationDialogBody =
    'MeshMapper needs your precise location to map coverage. Approximate '
    'location is off by too much for the map to use.';

/// Title of the zone check screen while only approximate location is granted.
const String preciseLocationOffTitle = 'Precise Location Is Off';

/// Body of the zone check screen while only approximate location is granted.
const String preciseLocationOffBody =
    'MeshMapper only has your approximate location, which is off by too much '
    'to map coverage.\n\nTurn on Precise Location for MeshMapper in your '
    "phone's settings, then come back to the app.";

/// What Siri says when the connect intent is refused for approximate location.
const String preciseLocationVoiceMessage =
    'MeshMapper needs Precise Location. Turn it on for MeshMapper in '
    'Settings, then try again.';

/// Which platform rules apply to the check.
enum PreciseLocationPlatform { ios, android, web }

/// What the connect should do next about location accuracy.
enum PreciseLocationStep {
  /// The check does not apply (web, GPS simulator, no location permission).
  skip,

  /// Precise location (or unreadable accuracy): carry on with the connect.
  connect,

  /// iOS: ask for temporary full accuracy, then decide again.
  askTemporaryFullAccuracy,

  /// Android: re-request fine location once, then decide again.
  requestFineLocation,

  /// Still approximate: do not connect, explain and offer the settings.
  block,
}

/// Decides the next step of the Precise Location check.
///
/// [locationGranted] false leaves the connect to the existing denied path.
/// [accuracy] null or `unknown` (the read failed) fails open. [alreadyAsked]
/// is true once the prompt has been shown this connect, so it is shown at
/// most once. [canPrompt] is false when no prompt can be shown (the app is
/// not on screen, or no screen has registered the Android re-request).
@visibleForTesting
PreciseLocationStep decidePreciseLocationStep({
  required PreciseLocationPlatform platform,
  required bool simulatorEnabled,
  required bool locationGranted,
  required LocationAccuracyStatus? accuracy,
  required bool alreadyAsked,
  required bool canPrompt,
}) {
  if (platform == PreciseLocationPlatform.web || simulatorEnabled) {
    return PreciseLocationStep.skip;
  }
  if (!locationGranted) return PreciseLocationStep.skip;
  if (accuracy != LocationAccuracyStatus.reduced) {
    return PreciseLocationStep.connect;
  }
  if (alreadyAsked || !canPrompt) return PreciseLocationStep.block;
  return platform == PreciseLocationPlatform.ios
      ? PreciseLocationStep.askTemporaryFullAccuracy
      : PreciseLocationStep.requestFineLocation;
}

/// Runs [decidePreciseLocationStep] against the platform.
class PreciseLocationGate {
  PreciseLocationGate({
    Future<bool> Function()? checkGranted,
    Future<LocationAccuracyStatus> Function()? readAccuracy,
    Future<LocationAccuracyStatus> Function()? requestTemporaryFullAccuracy,
  })  : _checkGranted = checkGranted ?? _platformGranted,
        _readAccuracy = readAccuracy ?? Geolocator.getLocationAccuracy,
        _requestTemporaryFullAccuracy = requestTemporaryFullAccuracy ??
            (() => Geolocator.requestTemporaryFullAccuracy(
                  purposeKey: preciseLocationPurposeKey,
                ));

  final Future<bool> Function() _checkGranted;
  final Future<LocationAccuracyStatus> Function() _readAccuracy;
  final Future<LocationAccuracyStatus> Function() _requestTemporaryFullAccuracy;

  static Future<bool> _platformGranted() async {
    final permission = await Geolocator.checkPermission();
    return permission == LocationPermission.whileInUse ||
        permission == LocationPermission.always;
  }

  /// Null when the read fails, which the decision treats as fail-open.
  Future<LocationAccuracyStatus?> _tryReadAccuracy() async {
    try {
      return await _readAccuracy();
    } catch (e) {
      debugWarn('[GPS] Precise location check: accuracy read failed, '
          'allowing the connect: $e');
      return null;
    }
  }

  /// Whether location is granted but only approximate. False when the check
  /// does not apply (web, GPS simulator, no permission) or a read fails.
  /// Reads only, never prompts.
  Future<bool> isApproximateOnly({
    required PreciseLocationPlatform platform,
    required bool simulatorEnabled,
  }) async {
    if (platform == PreciseLocationPlatform.web || simulatorEnabled) {
      return false;
    }
    try {
      if (!await _checkGranted()) return false;
      return await _readAccuracy() == LocationAccuracyStatus.reduced;
    } catch (e) {
      debugWarn('[GPS] Location accuracy read failed: $e');
      return false;
    }
  }

  /// The platform this build runs on, as the check sees it.
  static PreciseLocationPlatform get currentPlatform {
    if (kIsWeb) return PreciseLocationPlatform.web;
    return defaultTargetPlatform == TargetPlatform.iOS
        ? PreciseLocationPlatform.ios
        : PreciseLocationPlatform.android;
  }

  /// True when the connect may go ahead.
  ///
  /// [requestFineLocation] (Android) shows the location disclosure and
  /// re-requests the permission; null means it cannot be shown now. [entry]
  /// names the connect path in the log.
  Future<bool> allowsConnect({
    required PreciseLocationPlatform platform,
    required bool simulatorEnabled,
    required bool canPrompt,
    Future<bool> Function()? requestFineLocation,
    required String entry,
  }) async {
    if (platform == PreciseLocationPlatform.web || simulatorEnabled) {
      debugLog('[GPS] Precise location check skipped for $entry connect '
          '(${simulatorEnabled ? 'GPS simulator' : 'web'})');
      return true;
    }

    bool granted;
    try {
      granted = await _checkGranted();
    } catch (e) {
      debugWarn('[GPS] Precise location check: permission read failed: $e');
      granted = false;
    }

    var asked = false;
    var accuracy = granted ? await _tryReadAccuracy() : null;
    while (true) {
      final step = decidePreciseLocationStep(
        platform: platform,
        simulatorEnabled: simulatorEnabled,
        locationGranted: granted,
        accuracy: accuracy,
        alreadyAsked: asked,
        canPrompt: canPrompt &&
            (platform == PreciseLocationPlatform.ios ||
                requestFineLocation != null),
      );
      switch (step) {
        case PreciseLocationStep.skip:
          debugLog('[GPS] Precise location check skipped for $entry connect '
              '(location not granted, left to the permission path)');
          return true;
        case PreciseLocationStep.connect:
          debugLog('[GPS] Precise location check for $entry connect: '
              '${accuracy?.name ?? 'unreadable'}'
              '${asked ? ' after the prompt' : ''}, connecting');
          return true;
        case PreciseLocationStep.askTemporaryFullAccuracy:
          debugLog('[GPS] Location accuracy is reduced, showing the iOS '
              'temporary precise location prompt');
          asked = true;
          try {
            accuracy = await _requestTemporaryFullAccuracy();
            debugLog('[GPS] Temporary precise location prompt returned '
                '${accuracy.name}');
          } catch (e) {
            debugWarn('[GPS] Temporary precise location prompt failed: $e');
            // Counted as declined, not as unreadable (which fails open).
            accuracy = LocationAccuracyStatus.reduced;
          }
        case PreciseLocationStep.requestFineLocation:
          debugLog('[GPS] Location accuracy is reduced, re-requesting fine '
              'location (Android precise upgrade)');
          asked = true;
          try {
            final shown = await requestFineLocation!();
            debugLog('[GPS] Fine location re-request '
                '${shown ? 'shown' : 'not shown'}');
          } catch (e) {
            debugWarn('[GPS] Fine location re-request failed: $e');
          }
          accuracy = await _tryReadAccuracy();
        case PreciseLocationStep.block:
          debugWarn('[GPS] Connect refused for $entry: location accuracy is '
              'reduced${asked ? ' after the prompt' : ' (no prompt possible)'}');
          return false;
      }
    }
  }
}
