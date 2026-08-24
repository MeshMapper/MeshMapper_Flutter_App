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
      reason: 'No remembered companion',
    );
  }
  if (isConnected) {
    return ExternalCommandAdmission(
      disposition: isConnectedToRememberedCompanion
          ? ExternalCommandDisposition.noOp
          : ExternalCommandDisposition.refused,
      reason: isConnectedToRememberedCompanion
          ? 'Already connected'
          : 'Another companion is connected',
    );
  }
  if (isConnecting) {
    return const ExternalCommandAdmission(
      disposition: ExternalCommandDisposition.refused,
      reason: 'Already connecting',
    );
  }
  if (!canReconnectWithoutUserInput) {
    return const ExternalCommandAdmission(
      disposition: ExternalCommandDisposition.refused,
      reason: 'User interaction required',
    );
  }
  return const ExternalCommandAdmission(
    disposition: ExternalCommandDisposition.admitted,
  );
}
