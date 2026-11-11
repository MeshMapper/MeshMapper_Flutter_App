import '../external_commands/external_command_models.dart';
import '../external_commands/external_session_commands.dart';
import 'app_intent_commands.dart';

ExternalCommandAdmission resolveLastCompanionConnection({
  required AppIntentCommand command,
  required bool hasRememberedCompanion,
  required bool isConnected,
  required bool isConnectedToRememberedCompanion,
  required bool isConnecting,
  required bool canReconnectWithoutUserInput,
  required bool isAirborne,
  DateTime? now,
}) {
  // The deadline comes first: it is the instant the intent actually stops
  // waiting, and it is set when the command reaches Dart rather than when it
  // was created, so it can differ from the shared age rule in both directions.
  final ageRefusal = externalCommandDeadlineRefusal(
        command.expiresAt,
        now: now,
      ) ??
      externalCommandTimestampRefusal(
        command.issuedAt,
        now: now,
      );
  if (ageRefusal != null) {
    return ExternalCommandAdmission(
      disposition: ExternalCommandDisposition.refused,
      reason: ageRefusal,
    );
  }
  if (!hasRememberedCompanion) {
    return const ExternalCommandAdmission(
      disposition: ExternalCommandDisposition.refused,
      reason: ExternalCommandReason.noRememberedCompanion,
    );
  }
  // The connect entry points refuse while the GPS says aircraft; say so here
  // instead of letting the refusal surface as a generic "could not connect".
  if (isAirborne) {
    return const ExternalCommandAdmission(
      disposition: ExternalCommandDisposition.refused,
      reason: ExternalCommandReason.airborne,
    );
  }
  if (isConnected) {
    return ExternalCommandAdmission(
      disposition: isConnectedToRememberedCompanion
          ? ExternalCommandDisposition.noOp
          : ExternalCommandDisposition.refused,
      reason: isConnectedToRememberedCompanion
          ? ExternalCommandReason.alreadyConnected
          : ExternalCommandReason.anotherCompanionConnected,
    );
  }
  if (isConnecting) {
    return const ExternalCommandAdmission(
      disposition: ExternalCommandDisposition.refused,
      reason: ExternalCommandReason.alreadyConnecting,
    );
  }
  if (!canReconnectWithoutUserInput) {
    return const ExternalCommandAdmission(
      disposition: ExternalCommandDisposition.refused,
      reason: ExternalCommandReason.userInteractionRequired,
    );
  }
  return const ExternalCommandAdmission(
    disposition: ExternalCommandDisposition.admitted,
  );
}

/// Longest the connect intent waits for the dial to finish before answering.
///
/// A reachable radio connects in 4 to 7 seconds (measured on device), so this
/// covers the ordinary case with room to spare. An unreachable one would run
/// three 15 second BLE attempts, far past iOS's 30 second limit on the intent,
/// so past this point the intent answers "connecting" and the dial carries on.
const Duration lastCompanionQuickAnswer = Duration(seconds: 12);

/// Kept clear of the intent's own deadline so the answer reaches native code
/// before it stops waiting.
const Duration lastCompanionAnswerMargin = Duration(seconds: 3);

/// How long to wait for the reconnect before answering that it is underway.
///
/// [lastCompanionQuickAnswer], shortened when the intent's deadline is closer
/// than that plus [lastCompanionAnswerMargin] (a cold launch spends part of the
/// budget before the command arrives). Never negative.
Duration lastCompanionAnswerWindow(DateTime? expiresAt, {DateTime? now}) {
  if (expiresAt == null) return lastCompanionQuickAnswer;
  final left = expiresAt.difference(now ?? DateTime.now()) -
      lastCompanionAnswerMargin;
  if (left <= Duration.zero) return Duration.zero;
  return left < lastCompanionQuickAnswer ? left : lastCompanionQuickAnswer;
}
