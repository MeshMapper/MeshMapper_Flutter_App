import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/external_commands/external_command_models.dart';
import 'package:mesh_mapper/services/external_commands/external_session_commands.dart';

ExternalSessionCommand command({
  ExternalSessionCommandKind kind = ExternalSessionCommandKind.startSession,
  ExternalCommandSource source = ExternalCommandSource.siri,
  String? mode = 'passive',
  String? sessionId,
  DateTime? issuedAt,
}) =>
    ExternalSessionCommand(
      id: 'command-1',
      source: source,
      kind: kind,
      issuedAt: issuedAt ?? DateTime.fromMillisecondsSinceEpoch(100000),
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
    }) =>
        resolveExternalSessionTransition(
          command: value,
          isSessionActive: active,
          isSessionStarting: starting,
          currentMode: currentMode,
          currentSessionId: currentSessionId,
          now: now,
        );

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
      expect(trace.reason, 'Unsupported start mode');
    });

    test('duplicate Start and idle Stop are first-class no-ops', () {
      final duplicate = resolve(command(), active: true);
      final idleStop = resolve(command(
        kind: ExternalSessionCommandKind.stopSession,
        mode: null,
      ));

      expect(duplicate.disposition, ExternalCommandDisposition.noOp);
      expect(duplicate.reason, contains('already running'));
      expect(idleStop.disposition, ExternalCommandDisposition.noOp);
      expect(idleStop.reason, contains("isn't"));
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
      expect(admission.reason, 'That session already ended');
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

      expect(start.reason, 'Took too long to reach iPhone');
      expect(ping.reason, 'Took too long to reach iPhone');
      expect(stop.disposition, ExternalCommandDisposition.admitted);
    });

    test('future timestamps beyond tolerance are refused', () {
      final admission = resolve(
        command(issuedAt: now.add(const Duration(seconds: 6))),
      );

      expect(admission.disposition, ExternalCommandDisposition.refused);
    });
  });
}
