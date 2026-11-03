/// When GPS and Android's background session service may run.
///
/// Location is collected in the background only while a radio session is live.
/// A session is live from the Connect tap until cleanup finishes, which covers
/// connecting, connected, disconnecting, auto-reconnecting and a pending
/// connect re-run. Outside a session, a backgrounded app collects nothing.
///
/// |                      | App on screen      | App in background                |
/// |----------------------|--------------------|----------------------------------|
/// | No radio session     | GPS on (unchanged) | GPS off                          |
/// | Radio session live   | GPS on             | GPS on (see the platform note)   |
///
/// On Android the background GPS runs under the session service, which keeps
/// the process alive. On iOS an already-running stream is kept, but GPS is
/// never started in the background: a stream started there stays quiet, so
/// the status never reaches `GpsStatus.locked`, which `canPing` needs.
///
/// Pure, so the whole table is checkable without a device.
library;

import 'dart:ui' show AppLifecycleState;

import '../models/connection_state.dart';

/// True while a radio session is live: every step except
/// [ConnectionStep.disconnected] and [ConnectionStep.error], or whenever a
/// reconnect or a pending connect re-run is in flight.
///
/// The flags matter because both run while [step] reads `disconnected`, yet
/// the session is not over.
bool radioSessionActive({
  required ConnectionStep step,
  required bool autoReconnecting,
  required bool connectRerunPending,
}) {
  if (autoReconnecting || connectRerunPending) return true;
  return step != ConnectionStep.disconnected && step != ConnectionStep.error;
}

/// What a lifecycle change should do to the GPS stream.
///
/// [keep] means leave it as it is: `inactive` is a transient state (a system
/// dialog, the app switcher) and must not tear GPS down or start it.
enum GpsRunDecision { run, stop, keep }

/// Decides what the GPS stream should do for the current [lifecycle].
///
/// Checked in order: a resumed app always runs; a live radio session runs on
/// Android and only keeps on iOS (see the library comment); then a backgrounded
/// app stops; anything else, `inactive` or an unknown lifecycle, keeps.
GpsRunDecision gpsRunDecision({
  required AppLifecycleState? lifecycle,
  required bool radioActive,
  required bool isIos,
}) {
  if (lifecycle == AppLifecycleState.resumed) return GpsRunDecision.run;
  if (radioActive) return isIos ? GpsRunDecision.keep : GpsRunDecision.run;
  switch (lifecycle) {
    case AppLifecycleState.paused:
    case AppLifecycleState.hidden:
    case AppLifecycleState.detached:
      return GpsRunDecision.stop;
    case AppLifecycleState.resumed:
    case AppLifecycleState.inactive:
    case null:
      return GpsRunDecision.keep;
  }
}

/// True when the Android session service should be started now.
///
/// Every input must hold: the platform follows the connection
/// ([followsConnection]), the service is neither [running] nor [starting], a
/// radio session is live ([sessionActive]) and not already
/// [ConnectionStep.disconnecting], the app is on screen ([lifecycle] resumed,
/// because Android refuses to start a location service from the background),
/// and location permission is granted ([locationGranted]).
bool shouldStartConnectionService({
  required bool followsConnection,
  required bool running,
  required bool starting,
  required bool sessionActive,
  required ConnectionStep step,
  required AppLifecycleState? lifecycle,
  required bool locationGranted,
}) {
  return followsConnection &&
      !running &&
      !starting &&
      sessionActive &&
      step != ConnectionStep.disconnecting &&
      lifecycle == AppLifecycleState.resumed &&
      locationGranted;
}

/// True when the end of disconnect cleanup should stop the session service.
///
/// A service that does not follow the connection always stops here. One that
/// does follow it stays up while another session (a reconnect or a re-run) is
/// still live.
bool shouldStopServiceAtCleanupEnd({
  required bool followsConnection,
  required bool sessionActive,
}) =>
    !followsConnection || !sessionActive;
