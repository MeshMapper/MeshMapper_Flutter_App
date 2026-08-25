import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/app_intents/app_intent_commands.dart';
import 'package:mesh_mapper/services/app_intents/last_companion_connection.dart';
import 'package:mesh_mapper/services/external_commands/external_command_models.dart';
import 'package:mesh_mapper/services/external_commands/external_session_commands.dart';

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(100000);

  AppIntentCommand command({DateTime? issuedAt}) => AppIntentCommand(
        id: 'connect-1',
        kind: AppIntentCommandKind.connectLastCompanion,
        issuedAt: issuedAt ?? now,
      );

  ExternalCommandAdmission resolve({
    bool remembered = true,
    bool connected = false,
    bool connectedToRemembered = false,
    bool connecting = false,
    bool unattended = true,
    DateTime? issuedAt,
  }) =>
      resolveLastCompanionConnection(
        command: command(issuedAt: issuedAt),
        hasRememberedCompanion: remembered,
        isConnected: connected,
        isConnectedToRememberedCompanion: connectedToRemembered,
        isConnecting: connecting,
        canReconnectWithoutUserInput: unattended,
        now: now,
      );

  test('admits an unattended reconnect to the remembered companion', () {
    expect(resolve().disposition, ExternalCommandDisposition.admitted);
  });

  test('already connected to the remembered companion is a no-op', () {
    final result = resolve(
      connected: true,
      connectedToRemembered: true,
    );

    expect(result.disposition, ExternalCommandDisposition.noOp);
    expect(result.reason?.compactText, 'Already connected');
  });

  test('fails closed for missing, busy, switched, and USB companions', () {
    expect(
      resolve(remembered: false).reason?.compactText,
      'No remembered companion',
    );
    expect(
      resolve(connecting: true).reason?.compactText,
      'Already connecting',
    );
    expect(
      resolve(connected: true).reason?.compactText,
      'Another companion is connected',
    );
    expect(
      resolve(unattended: false).reason?.compactText,
      'User interaction required',
    );
  });

  test('stale and future connect commands are refused', () {
    expect(
      resolve(issuedAt: now.subtract(const Duration(seconds: 31)))
          .reason
          ?.compactText,
      externalCommandExpiredReason,
    );
    expect(
      resolve(issuedAt: now.add(const Duration(seconds: 6)))
          .reason
          ?.compactText,
      externalCommandExpiredReason,
    );
  });
}
