import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/app_intents/app_intent_commands.dart';
import 'package:mesh_mapper/services/app_intents/last_companion_connection.dart';
import 'package:mesh_mapper/services/external_commands/external_command_models.dart';
import 'package:mesh_mapper/services/external_commands/external_session_commands.dart';

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(100000);

  AppIntentCommand command({DateTime? issuedAt, DateTime? expiresAt}) =>
      AppIntentCommand(
        id: 'connect-1',
        kind: AppIntentCommandKind.connectLastCompanion,
        issuedAt: issuedAt ?? now,
        expiresAt: expiresAt,
      );

  ExternalCommandAdmission resolve({
    bool remembered = true,
    bool connected = false,
    bool connectedToRemembered = false,
    bool connecting = false,
    bool unattended = true,
    DateTime? issuedAt,
    DateTime? expiresAt,
  }) =>
      resolveLastCompanionConnection(
        command: command(issuedAt: issuedAt, expiresAt: expiresAt),
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

  group("Connect honours the intent's deadline", () {
    test('a passed deadline is refused even while the command is young', () {
      // Connect's deadline is set when the command reaches Dart, so it can pass
      // well before the shared 30-second age rule would refuse the command.
      final admission = resolve(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      );

      expect(admission.disposition, ExternalCommandDisposition.refused);
      expect(admission.reason?.compactText, externalCommandExpiredReason);
    });

    test('a live deadline still admits', () {
      expect(
        resolve(expiresAt: now.add(const Duration(seconds: 20))).disposition,
        ExternalCommandDisposition.admitted,
      );
    });

    test('the deadline is checked before every other refusal', () {
      // Expiry is about whether anyone is still listening, so it outranks the
      // state-based refusals; reporting "already connecting" to a caller that
      // has gone would be answering a question nobody asked.
      final admission = resolve(
        connecting: true,
        expiresAt: now.subtract(const Duration(seconds: 1)),
      );

      expect(admission.reason?.compactText, externalCommandExpiredReason);
    });

    test('an older native build sending no deadline is unaffected', () {
      expect(resolve().disposition, ExternalCommandDisposition.admitted);
    });
  });
}
