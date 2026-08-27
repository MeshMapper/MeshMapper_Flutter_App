import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/external_commands/external_command_models.dart';
import 'package:mesh_mapper/services/external_commands/external_session_commands.dart';

ExternalSessionCommand command({
  ExternalSessionCommandKind kind = ExternalSessionCommandKind.startSession,
  ExternalCommandSource source = ExternalCommandSource.siri,
  String? mode = 'passive',
  String? sessionId,
  DateTime? issuedAt,
  DateTime? expiresAt,
}) =>
    ExternalSessionCommand(
      id: 'command-1',
      source: source,
      kind: kind,
      issuedAt: issuedAt ?? DateTime.fromMillisecondsSinceEpoch(100000),
      expiresAt: expiresAt,
      mode: mode,
      sessionId: sessionId,
    );

void main() {
  final now = DateTime.fromMillisecondsSinceEpoch(100000);

  group('wire decoding', () {
    test('accepts only a complete Siri payload', () {
      final decoded = ExternalSessionCommand.fromMap(
        {
          'id': 'abc',
          'source': 'siri',
          'kind': 'startSession',
          'issuedAtMs': 100000,
          'mode': 'hybrid',
          'sessionId': null,
        },
        expectedSource: ExternalCommandSource.siri,
      );

      expect(decoded, isNotNull);
      expect(decoded!.kind, ExternalSessionCommandKind.startSession);
      expect(decoded.mode, 'hybrid');
    });

    test('rejects another transport and unknown commands', () {
      expect(
        ExternalSessionCommand.fromMap(
          {
            'id': 'abc',
            'source': 'watch',
            'kind': 'startSession',
            'issuedAtMs': 100000,
          },
          expectedSource: ExternalCommandSource.siri,
        ),
        isNull,
      );
      expect(
        ExternalSessionCommand.fromMap(
          {
            'id': 'abc',
            'source': 'siri',
            'kind': 'traceRepeater',
            'issuedAtMs': 100000,
          },
          expectedSource: ExternalCommandSource.siri,
        ),
        isNull,
      );
    });
  });

  group('transition admission', () {
    ExternalCommandAdmission resolve(
      ExternalSessionCommand value, {
      bool active = false,
      bool starting = false,
      String currentMode = 'hybrid',
      String currentSessionId = 'session-a',
      String currentModeLabel = 'Hybrid',
    }) =>
        resolveExternalSessionTransition(
          command: value,
          isSessionActive: active,
          isSessionStarting: starting,
          currentMode: currentMode,
          currentSessionId: currentSessionId,
          currentModeLabel: currentModeLabel,
          now: now,
        );

    test('a running session is named the way the app names it, not the wire',
        () {
      final admission = resolve(
        command(),
        active: true,
        currentMode: 'targeted',
        currentModeLabel: 'Trace',
      );

      expect(
        admission.reason?.compactText,
        'MeshMapper is already running in Trace mode.',
      );
    });

    test('Siri defaults an unqualified Start to Passive Discovery', () {
      final admission = resolve(command(mode: null));

      expect(admission.disposition, ExternalCommandDisposition.admitted);
      expect(admission.mode, ExternalSessionMode.passive);
    });

    test('all three general modes are admitted and Trace is refused', () {
      for (final mode in ['active', 'passive', 'hybrid']) {
        expect(
          resolve(command(mode: mode)).mode?.name,
          mode,
        );
      }
      final trace = resolve(command(mode: 'targeted'));
      expect(trace.disposition, ExternalCommandDisposition.refused);
      expect(trace.reason?.compactText, 'Unsupported start mode');
    });

    test('voice refusal expands Passive Only with mode and next step', () {
      final requested = command(mode: 'hybrid');
      final completion = externalCommandCompletionForVoice(
        command: requested,
        completion: const ExternalCommandCompletion(
          success: false,
          disposition: ExternalCommandDisposition.refused,
          message: ExternalCommandReason.passiveOnly,
          sessionId: 'session-1',
          mode: ExternalSessionMode.hybrid,
        ),
      );

      expect(
        completion.message?.compactText,
        "Hybrid mode isn't available in this region. Start Passive Discovery instead.",
      );
      expect(completion.sessionId, 'session-1');
      expect(completion.mode, ExternalSessionMode.hybrid);
    });

    test('voice presentation expands common compact admission labels', () {
      final requested = command(mode: 'active');
      final expected = <ExternalCommandReason, String>{
        ExternalCommandReason.notConnected:
            "MeshMapper isn't connected. Reconnect it, then try again.",
        ExternalCommandReason.notConnectedToDevice:
            "MeshMapper isn't connected. Reconnect it, then try again.",
        ExternalCommandReason.stillStopping:
            'MeshMapper is still stopping. Try again shortly.',
        ExternalCommandReason.traceSessionActive:
            'Stop the active Trace session before starting Active mode.',
        ExternalCommandReason.alreadyStarting:
            'MeshMapper is already starting a session.',
        ExternalCommandReason.coolingDown:
            'MeshMapper is cooling down. Try again shortly.',
        ExternalCommandReason.waitFiveSeconds:
            'MeshMapper is cooling down. Try again shortly.',
        ExternalCommandReason.waitFifteenSeconds:
            'MeshMapper is cooling down. Try again shortly.',
        ExternalCommandReason.waitingForGpsLock:
            'MeshMapper is waiting for a GPS fix. Try again shortly.',
        ExternalCommandReason.selectAntennaOption:
            'Select an antenna option in MeshMapper, then try again.',
        ExternalCommandReason.selectAntennaOptionBeforePinging:
            'Select an antenna option in MeshMapper, then try again.',
        ExternalCommandReason.selectPowerLevel:
            'Select a power level in MeshMapper, then try again.',
        ExternalCommandReason.selectPowerLevelUnknownDevice:
            'Select a power level in MeshMapper, then try again.',
        ExternalCommandReason.offlineMode:
            "Active mode isn't available in Offline Mode. Start Passive Discovery instead.",
        ExternalCommandReason.passiveOnly:
            "Active mode isn't available in this region. Start Passive Discovery instead.",
        ExternalCommandReason.zoneAtCapacity:
            "Active mode isn't available in this region. Start Passive Discovery instead.",
        ExternalCommandReason.floodTrafficOff:
            'Active mode requires Flood Traffic. Enable it or start Passive Discovery.',
        ExternalCommandReason.pingInProgress:
            'A ping is already in progress. Try again when it finishes.',
        ExternalCommandReason.listeningForPingResponse:
            'MeshMapper is listening for a response. Try again shortly.',
        ExternalCommandReason.gpsDataStale:
            'MeshMapper needs a current GPS position. Let location refresh, then retry.',
        ExternalCommandReason.gpsAccuracyLow:
            'GPS accuracy is too low. Try again when it improves.',
        ExternalCommandReason.anotherOperationInProgress:
            'Another radio operation is in progress. Try again shortly.',
        ExternalCommandReason.stillStartingTryStopAgain:
            'MeshMapper is still starting. Try Stop again shortly.',
        ExternalCommandReason.sessionAlreadyEnded:
            'That session already ended. There is nothing to stop.',
        ExternalCommandReason.couldNotStart:
            "MeshMapper couldn't start Active mode.",
        ExternalCommandReason.couldNotStop:
            "MeshMapper couldn't stop. Check the app for details.",
        ExternalCommandReason.pingFailed:
            "MeshMapper couldn't send the manual ping. Open the app for details.",
        ExternalCommandReason.appClosing:
            'MeshMapper is closing. Open it and try again.',
      };

      for (final entry in expected.entries) {
        final completion = externalCommandCompletionForVoice(
          command: requested,
          completion: ExternalCommandCompletion(
            success: false,
            disposition: ExternalCommandDisposition.refused,
            message: entry.key,
          ),
        );
        expect(
          completion.message?.compactText,
          entry.value,
          reason: entry.key.compactText,
        );
      }
    });

    test('voice presentation preserves already complete responses', () {
      final requested = command(mode: 'passive');
      const original = ExternalCommandCompletion(
        success: true,
        disposition: ExternalCommandDisposition.admitted,
        message: ExternalCommandReason.other(
          'MeshMapper started in Passive Discovery mode.',
        ),
      );

      expect(
        externalCommandCompletionForVoice(
          command: requested,
          completion: original,
        ),
        same(original),
      );
    });

    test('duplicate Start and idle Stop are first-class no-ops', () {
      final duplicate = resolve(command(), active: true);
      final duplicateStarting = resolve(command(), starting: true);
      final idleStop = resolve(command(
        kind: ExternalSessionCommandKind.stopSession,
        mode: null,
      ));
      final stoppingWhileStarting = resolve(
        command(
          kind: ExternalSessionCommandKind.stopSession,
          mode: null,
        ),
        starting: true,
      );

      expect(duplicate.disposition, ExternalCommandDisposition.noOp);
      expect(duplicate.reason?.compactText, contains('already running'));
      expect(duplicateStarting.disposition, ExternalCommandDisposition.noOp);
      expect(
        duplicateStarting.reason?.compactText,
        contains('already starting'),
      );
      expect(idleStop.disposition, ExternalCommandDisposition.noOp);
      expect(idleStop.reason?.compactText, contains("isn't"));
      expect(
        stoppingWhileStarting.disposition,
        ExternalCommandDisposition.refused,
      );
      expect(
        stoppingWhileStarting.reason?.compactText,
        'Still starting, try Stop again',
      );
    });

    test('Stop cannot terminate a newer session', () {
      final admission = resolve(
        command(
          kind: ExternalSessionCommandKind.stopSession,
          mode: null,
          sessionId: 'session-a',
        ),
        active: true,
        currentSessionId: 'session-b',
      );

      expect(admission.disposition, ExternalCommandDisposition.refused);
      expect(admission.reason?.compactText, 'That session already ended');

      final sameSession = resolve(
        command(
          kind: ExternalSessionCommandKind.stopSession,
          mode: null,
          sessionId: 'session-b',
        ),
        active: true,
        currentSessionId: 'session-b',
      );
      final olderWatch = resolve(
        command(
          kind: ExternalSessionCommandKind.stopSession,
          mode: null,
        ),
        active: true,
        currentSessionId: 'session-b',
      );
      expect(sameSession.disposition, ExternalCommandDisposition.admitted);
      expect(olderWatch.disposition, ExternalCommandDisposition.admitted);
    });

    test('Stop is age exempt but Start and Manual Ping expire', () {
      final stale = now.subtract(const Duration(seconds: 31));
      final start = resolve(command(issuedAt: stale));
      final ping = resolve(command(
        kind: ExternalSessionCommandKind.manualPing,
        mode: null,
        issuedAt: stale,
      ));
      final stop = resolve(
        command(
          kind: ExternalSessionCommandKind.stopSession,
          mode: null,
          sessionId: 'session-a',
          issuedAt: stale,
        ),
        active: true,
      );

      expect(start.reason?.compactText, externalCommandExpiredReason);
      expect(ping.reason?.compactText, externalCommandExpiredReason);
      expect(stop.disposition, ExternalCommandDisposition.admitted);
    });

    test('future timestamps beyond tolerance are refused', () {
      final admission = resolve(
        command(issuedAt: now.add(const Duration(seconds: 6))),
      );

      expect(admission.disposition, ExternalCommandDisposition.refused);
    });
  });

  group("the issuing surface's deadline", () {
    test('a passed deadline refuses a Start that is still young enough', () {
      // Siri gives up long before the shared 30-second age rule would.
      final admission = resolveExternalSessionTransition(
        command: command(expiresAt: now.subtract(const Duration(seconds: 1))),
        isSessionActive: false,
        isSessionStarting: false,
        currentMode: 'passive',
        currentSessionId: 'session-a',
        currentModeLabel: 'Passive',
        now: now,
      );

      expect(admission.disposition, ExternalCommandDisposition.refused);
      expect(admission.reason?.compactText, externalCommandExpiredReason);
    });

    test('Stop stays exempt, because stopping is the safe direction', () {
      final admission = resolveExternalSessionTransition(
        command: command(
          kind: ExternalSessionCommandKind.stopSession,
          mode: null,
          expiresAt: now.subtract(const Duration(seconds: 30)),
        ),
        isSessionActive: true,
        isSessionStarting: false,
        currentMode: 'passive',
        currentSessionId: 'session-a',
        currentModeLabel: 'Passive',
        now: now,
      );

      expect(admission.disposition, ExternalCommandDisposition.admitted);
    });

    test('a surface that names no deadline is unaffected', () {
      final admission = resolveExternalSessionTransition(
        command: command(),
        isSessionActive: false,
        isSessionStarting: false,
        currentMode: 'passive',
        currentSessionId: 'session-a',
        currentModeLabel: 'Passive',
        now: now,
      );

      expect(admission.disposition, ExternalCommandDisposition.admitted);
    });

    test('the commit gate closes before the deadline, not after it', () {
      // The awaited session check runs between admission and the radio. A
      // deadline with less than the margin left cannot be met by work that has
      // not started yet, so committing then would still land after Siri gave up.
      expect(
        externalCommandCannotCommit(
          now.add(const Duration(seconds: 5)),
          now: now,
        ),
        isFalse,
      );
      expect(
        externalCommandCannotCommit(
          now.add(externalCommandCommitMargin),
          now: now,
        ),
        isTrue,
      );
      expect(
        externalCommandCannotCommit(
          now.subtract(const Duration(seconds: 1)),
          now: now,
        ),
        isTrue,
      );
    });

    test('no deadline means nothing to miss', () {
      expect(externalCommandCannotCommit(null, now: now), isFalse);
      expect(externalCommandDeadlineRefusal(null, now: now), isNull);
    });

    test('an expired command gets a spoken reason, not the compact label', () {
      final expired = command(
        expiresAt: now.subtract(const Duration(seconds: 1)),
      );
      final spoken = externalCommandCompletionForVoice(
        command: expired,
        completion: const ExternalCommandCompletion(
          success: false,
          disposition: ExternalCommandDisposition.refused,
          message: ExternalCommandReason.commandExpired,
        ),
      );

      expect(spoken.message?.compactText, externalCommandExpiredVoiceMessage);
      expect(
        externalCommandExpiredVoiceMessage,
        isNot(externalCommandExpiredReason),
        reason: 'the watch keeps the terse label; voice gets the next step',
      );
    });
  });
}
