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
  DateTime? now,
}) {
  final ageRefusal = externalCommandTimestampRefusal(
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
