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
