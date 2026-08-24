import 'external_command_models.dart';

const Duration maximumExternalCommandAge = Duration(seconds: 30);
const Duration externalCommandFutureTolerance = Duration(seconds: 5);

String? externalCommandTimestampRefusal(
  DateTime issuedAt, {
  DateTime? now,
}) {
  final age = (now ?? DateTime.now()).difference(issuedAt);
  if (age > maximumExternalCommandAge ||
      age < -externalCommandFutureTolerance) {
    return 'Took too long to reach iPhone';
  }
  return null;
}

/// Reject commands whose delayed execution could transmit from the wrong
/// location. Stop is deliberately exempt and is instead bound to a session ID.
String? externalCommandAgeRefusal(
  ExternalSessionCommand command, {
  DateTime? now,
}) {
  if (command.kind == ExternalSessionCommandKind.stopSession) return null;
  return externalCommandTimestampRefusal(command.issuedAt, now: now);
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
          reason: 'MeshMapper is already running in $currentMode mode.',
        );
      }
      if (isSessionStarting) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.noOp,
          reason: 'MeshMapper is already starting.',
        );
      }
      final rawMode = command.mode ??
          (command.source == ExternalCommandSource.siri ? 'passive' : null);
      if (rawMode == null) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.refused,
          reason: 'No start mode was provided',
        );
      }
      final mode = ExternalSessionMode.fromWire(rawMode);
      if (mode == null) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.refused,
          reason: 'Unsupported start mode',
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
          reason: 'Still starting — try Stop again',
        );
      }
      if (!isSessionActive) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.noOp,
          reason: "There isn't a MeshMapper session running.",
        );
      }
      if (command.sessionId != null && command.sessionId != currentSessionId) {
        return const ExternalCommandAdmission(
          disposition: ExternalCommandDisposition.refused,
          reason: 'That session already ended',
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
