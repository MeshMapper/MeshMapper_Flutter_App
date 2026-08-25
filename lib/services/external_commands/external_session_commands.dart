import 'external_command_models.dart';

const Duration maximumExternalCommandAge = Duration(seconds: 30);
const Duration externalCommandFutureTolerance = Duration(seconds: 5);
String get externalCommandExpiredReason =>
    ExternalCommandReason.commandExpired.compactText;

ExternalCommandReason? externalCommandTimestampRefusal(
  DateTime issuedAt, {
  DateTime? now,
}) {
  final age = (now ?? DateTime.now()).difference(issuedAt);
  if (age > maximumExternalCommandAge ||
      age < -externalCommandFutureTolerance) {
    return ExternalCommandReason.commandExpired;
  }
  return null;
}

/// Reject commands whose delayed execution could transmit from the wrong
/// location. Stop is deliberately exempt and is instead bound to a session ID.
ExternalCommandReason? externalCommandAgeRefusal(
  ExternalSessionCommand command, {
  DateTime? now,
}) {
  if (command.kind == ExternalSessionCommandKind.stopSession) return null;
  return externalCommandTimestampRefusal(command.issuedAt, now: now);
}

/// Expands compact admission labels into complete, actionable voice responses.
///
/// Watch surfaces intentionally retain the short reason stored on the shared
/// admission result. Siri calls this only at its presentation boundary, so the
/// policy decision stays transport-neutral while a spoken refusal explains
/// what happened and, where possible, what the person can do next.
ExternalCommandCompletion externalCommandCompletionForVoice({
  required ExternalSessionCommand command,
  required ExternalCommandCompletion completion,
}) {
  final message = _externalCommandVoiceMessage(
    command: command,
    reason: completion.message,
  );
  if (message == completion.message?.compactText) return completion;
  return ExternalCommandCompletion(
    success: completion.success,
    disposition: completion.disposition,
    message: ExternalCommandReason.other(message),
    sessionId: completion.sessionId,
    mode: completion.mode,
  );
}

String _externalCommandVoiceMessage({
  required ExternalSessionCommand command,
  required ExternalCommandReason? reason,
}) {
  final compact = reason?.compactText.trim();
  if (compact == null || compact.isEmpty) {
    return switch (command.kind) {
      ExternalSessionCommandKind.startSession =>
        "MeshMapper couldn't start the requested session.",
      ExternalSessionCommandKind.stopSession =>
        "MeshMapper couldn't stop the current session.",
      ExternalSessionCommandKind.manualPing =>
        "MeshMapper couldn't send the manual ping.",
    };
  }

  final mode = ExternalSessionMode.fromWire(command.mode ?? '');
  final modeName = mode?.displayName ?? 'requested';
  final isStart = command.kind == ExternalSessionCommandKind.startSession;

  return switch (reason!.code) {
    ExternalCommandReasonCode.notConnected ||
    ExternalCommandReasonCode.notConnectedToDevice =>
      "MeshMapper isn't connected. Reconnect it, then try again.",
    ExternalCommandReasonCode.stillStopping =>
      'MeshMapper is still stopping. Try again shortly.',
    ExternalCommandReasonCode.traceSessionActive =>
      'Stop the active Trace session before starting $modeName mode.',
    ExternalCommandReasonCode.alreadyStarting =>
      'MeshMapper is already starting a session.',
    ExternalCommandReasonCode.selectAntennaOption ||
    ExternalCommandReasonCode.selectAntennaOptionBeforePinging =>
      'Select an antenna option in MeshMapper, then try again.',
    ExternalCommandReasonCode.selectPowerLevel ||
    ExternalCommandReasonCode.selectPowerLevelUnknownDevice =>
      'Select a power level in MeshMapper, then try again.',
    ExternalCommandReasonCode.offlineMode => isStart
        ? "$modeName mode isn't available in Offline Mode. Start Passive Discovery instead."
        : "Manual pings aren't available in Offline Mode. Turn it off and try again.",
    ExternalCommandReasonCode.passiveOnly ||
    ExternalCommandReasonCode.zoneAtCapacity =>
      isStart
          ? "$modeName mode isn't available in this region. Start Passive Discovery instead."
          : "Manual pings aren't available in this region. Passive Discovery still works.",
    ExternalCommandReasonCode.floodTrafficOff => isStart
        ? '$modeName mode requires Flood Traffic. Enable it or start Passive Discovery.'
        : 'Manual pings require Flood Traffic. Enable it and try again.',
    ExternalCommandReasonCode.coolingDown ||
    ExternalCommandReasonCode.waitFiveSeconds ||
    ExternalCommandReasonCode.waitFifteenSeconds =>
      'MeshMapper is cooling down. Try again shortly.',
    ExternalCommandReasonCode.pingInProgress =>
      'A ping is already in progress. Try again when it finishes.',
    ExternalCommandReasonCode.listeningForPingResponse =>
      'MeshMapper is listening for a response. Try again shortly.',
    ExternalCommandReasonCode.waitingForGpsLock =>
      'MeshMapper is waiting for a GPS fix. Try again shortly.',
    ExternalCommandReasonCode.gpsDataStale =>
      'MeshMapper needs a current GPS position. Let location refresh, then retry.',
    ExternalCommandReasonCode.gpsAccuracyLow =>
      'GPS accuracy is too low. Try again when it improves.',
    ExternalCommandReasonCode.anotherOperationInProgress =>
      'Another radio operation is in progress. Try again shortly.',
    ExternalCommandReasonCode.stillStartingTryStopAgain =>
      'MeshMapper is still starting. Try Stop again shortly.',
    ExternalCommandReasonCode.sessionAlreadyEnded =>
      'That session already ended. There is nothing to stop.',
    ExternalCommandReasonCode.couldNotStart =>
      "MeshMapper couldn't start $modeName mode.",
    ExternalCommandReasonCode.couldNotStop =>
      "MeshMapper couldn't stop. Check the app for details.",
    ExternalCommandReasonCode.pingFailed =>
      "MeshMapper couldn't send the manual ping. Open the app for details.",
    ExternalCommandReasonCode.appClosing =>
      'MeshMapper is closing. Open it and try again.',
    ExternalCommandReasonCode.commandExpired ||
    ExternalCommandReasonCode.noRememberedCompanion ||
    ExternalCommandReasonCode.alreadyConnected ||
    ExternalCommandReasonCode.anotherCompanionConnected ||
    ExternalCommandReasonCode.alreadyConnecting ||
    ExternalCommandReasonCode.userInteractionRequired ||
    ExternalCommandReasonCode.other =>
      compact,
  };
}

ExternalCommandAdmission resolveExternalSessionTransition({
  required ExternalSessionCommand command,
  required bool isSessionActive,
  required bool isSessionStarting,
  required String currentMode,
  required String currentSessionId,
  DateTime? now,
}) {
  final ageRefusal = externalCommandAgeRefusal(command, now: now);
  if (ageRefusal != null) {
    return ExternalCommandAdmission(
      disposition: ExternalCommandDisposition.refused,
      reason: ageRefusal,
    );
  }

  switch (command.kind) {
    case ExternalSessionCommandKind.startSession:
      if (isSessionActive) {
        return ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.noOp,
          reason: ExternalCommandReason.other(
            'MeshMapper is already running in $currentMode mode.',
          ),
        );
      }
      if (isSessionStarting) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.noOp,
          reason: ExternalCommandReason.other(
            'MeshMapper is already starting.',
          ),
        );
      }
      final rawMode = command.mode ??
          (command.source == ExternalCommandSource.siri ? 'passive' : null);
      if (rawMode == null) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.refused,
          reason: ExternalCommandReason.other('No start mode was provided'),
        );
      }
      final mode = ExternalSessionMode.fromWire(rawMode);
      if (mode == null) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.refused,
          reason: ExternalCommandReason.other('Unsupported start mode'),
        );
      }
      return ExternalCommandAdmission(
        disposition: ExternalCommandDisposition.admitted,
        mode: mode,
      );

    case ExternalSessionCommandKind.stopSession:
      if (isSessionStarting && !isSessionActive) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.refused,
          reason: ExternalCommandReason.stillStartingTryStopAgain,
        );
      }
      if (!isSessionActive) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.noOp,
          reason: ExternalCommandReason.other(
            "There isn't a MeshMapper session running.",
          ),
        );
      }
      if (command.sessionId != null && command.sessionId != currentSessionId) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.refused,
          reason: ExternalCommandReason.sessionAlreadyEnded,
        );
      }
      return ExternalCommandAdmission(
        disposition: ExternalCommandDisposition.admitted,
        mode: ExternalSessionMode.fromWire(currentMode.toLowerCase()),
      );

    case ExternalSessionCommandKind.manualPing:
      return const ExternalCommandAdmission(
        disposition: ExternalCommandDisposition.admitted,
      );
  }
}
