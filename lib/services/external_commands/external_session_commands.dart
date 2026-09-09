import 'external_command_models.dart';

const Duration maximumExternalCommandAge = Duration(seconds: 30);
const Duration externalCommandFutureTolerance = Duration(seconds: 5);

/// Headroom reserved at the last checkpoint before an irreversible side effect.
///
/// A deadline that has not quite passed is no use if the remaining work
/// outlives it: the surface would still have given up before the radio came up.
/// Refusing while this much is left keeps the two in the same order.
const Duration externalCommandCommitMargin = Duration(seconds: 2);

String get externalCommandExpiredReason =>
    ExternalCommandReason.commandExpired.compactText;

/// Spoken form of [ExternalCommandReasonCode.commandExpired].
///
/// The compact label stays terse for the watch; a voice surface has room to say
/// what to do next. Connect builds its own responses, so it reads this too
/// rather than growing a fourth copy of the sentence.
const String externalCommandExpiredVoiceMessage =
    'That request took too long to reach MeshMapper. Try again.';

/// Refuses a command whose issuing surface has already stopped waiting.
ExternalCommandReason? externalCommandDeadlineRefusal(
  DateTime? expiresAt, {
  DateTime? now,
}) {
  if (expiresAt == null) return null;
  return (now ?? DateTime.now()).isBefore(expiresAt)
      ? null
      : ExternalCommandReason.commandExpired;
}

/// Whether too little of the deadline is left to reach the radio in time.
///
/// Admission runs before the awaited session check; this runs after it, at the
/// last point where refusing is still free.
bool externalCommandCannotCommit(DateTime? expiresAt, {DateTime? now}) {
  if (expiresAt == null) return false;
  return !(now ?? DateTime.now())
      .add(externalCommandCommitMargin)
      .isBefore(expiresAt);
}

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
  return externalCommandDeadlineRefusal(command.expiresAt, now: now) ??
      externalCommandTimestampRefusal(command.issuedAt, now: now);
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
        ? "$modeName mode isn't available in Offline Mode. Start Passive mode instead."
        : "Manual pings aren't available in Offline Mode. Turn it off and try again.",
    ExternalCommandReasonCode.passiveOnly ||
    ExternalCommandReasonCode.zoneAtCapacity =>
      isStart
          ? "$modeName mode isn't available in this region. Start Passive mode instead."
          : "Manual pings aren't available in this region. Passive mode still works.",
    ExternalCommandReasonCode.floodTrafficOff => isStart
        ? '$modeName mode requires Flood Traffic. Enable it or start Passive mode.'
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
      'MeshMapper is waiting for GPS. Try again shortly.',
    ExternalCommandReasonCode.gpsDataStale =>
      'MeshMapper needs a current GPS position. Let location refresh, then retry.',
    ExternalCommandReasonCode.gpsAccuracyLow =>
      'Your GPS signal is too weak. Try again when it improves.',
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
    ExternalCommandReasonCode.commandExpired =>
      externalCommandExpiredVoiceMessage,
    ExternalCommandReasonCode.airborne =>
      "MeshMapper won't wardrive from an aircraft. Try again on the ground.",
    ExternalCommandReasonCode.noRememberedCompanion ||
    ExternalCommandReasonCode.alreadyConnected ||
    ExternalCommandReasonCode.anotherCompanionConnected ||
    ExternalCommandReasonCode.alreadyConnecting ||
    ExternalCommandReasonCode.userInteractionRequired ||
    ExternalCommandReasonCode.other =>
      compact,
  };
}

/// [currentMode] is the wire name of the running mode and is what the stop path
/// resolves back into an [ExternalSessionMode]. [currentModeLabel] is the name
/// a person hears, which the app spells differently (Trace, not targeted). It
/// is required: the wire name is not speakable, so falling back to it would
/// have put the enum spelling in a spoken sentence.
ExternalCommandAdmission resolveExternalSessionTransition({
  required ExternalSessionCommand command,
  required bool isSessionActive,
  required bool isSessionStarting,
  required bool isSessionStopping,
  required String currentMode,
  required String currentSessionId,
  required String currentModeLabel,
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
            'MeshMapper is already running in $currentModeLabel mode.',
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
      // A stop already draining behind an in-flight ping. The wearer's intent
      // is being carried out, so this is a no-op and not a refusal, the mirror
      // of a duplicate Start above.
      //
      // It has to be admitted nowhere, not merely answered politely: a second
      // Stop re-enters `disableAutoPing` after the in-flight ping has armed its
      // listening window, takes the immediate teardown branch, and disposes the
      // tracker whose window completion is the only thing that would have
      // drained the parked disable. The session then sat half stopped, with no
      // cooldown and the foreground service still up, until the 12 second
      // backstop fired.
      //
      // Ahead of the `!isSessionActive` test below on purpose: one stop path
      // (`_stopAutoPingGracefully`) clears the session flag while the disable is
      // still parked, and "there isn't a session running" would be the wrong
      // thing to say about a session that is visibly stopping.
      if (isSessionStopping) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.noOp,
          reason: ExternalCommandReason.other(
            'MeshMapper is already stopping.',
          ),
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
