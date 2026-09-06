import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/auto/auto_glance_view.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/watch/watch_models.dart';

final DateTime _now = DateTime.fromMillisecondsSinceEpoch(1760000000000);

WatchSnapshot _snapshot({
  WatchHapticCue? cue,
  String phaseTitle = 'Listening',
  String? phaseDetail = 'Waiting for echoes',
  LiveActivityPhase phase = LiveActivityPhase.listening,
  bool isConnected = true,
  bool isSessionActive = true,
  String sessionId = 'session-1',
  String mode = 'Active',
  String? zoneCode = 'SEA',
  String? blockedReason,
  int txCount = 3,
  int rxCount = 2,
  int discoveryCount = 1,
  int queueSize = 4,
  WatchGeo? geo,
}) =>
    WatchSnapshot(
      core: LiveActivitySnapshot(
        sessionId: sessionId,
        mode: mode,
        phase: phase,
        phaseTitle: phaseTitle,
        phaseDetail: phaseDetail,
        isConnected: isConnected,
        zoneCode: zoneCode,
        txCount: txCount,
        rxCount: rxCount,
        discoveryCount: discoveryCount,
        traceCount: 0,
        queueSize: queueSize,
        repeaters: const [],
        totalHeardCount: 0,
        repeatersAreCurrent: true,
        updatedAt: _now,
      ),
      geo: geo ??
          const WatchGeo(
            pings: [],
            repeaters: [],
            heard: [],
            linkedRepeaterIds: [],
          ),
      controls: WatchControls(
        canStartStop: true,
        canManualPing: false,
        isSessionActive: isSessionActive,
        blockedReason: blockedReason,
      ),
      cue: cue,
      updatedAt: _now,
    );

void main() {
  group('layout contract', () {
    // These are not cosmetic assertions. Android Auto allows a pane update to be
    // a free "refresh" only while the row count and row titles are unchanged;
    // anything else counts against a five-template-per-task quota, and a driver
    // on a long wardrive would watch the surface stop updating. Changing what
    // these pin means re-checking the quota on the Desktop Head Unit's debug
    // overlay, not just re-recording the expectation.
    //
    // One row, not four: the content panel is what crowds the map, and the
    // controls moved to the map action strip.
    test('always renders exactly one row', () {
      for (final snapshot in [
        _snapshot(),
        _snapshot(isSessionActive: false, phase: LiveActivityPhase.idle),
        _snapshot(isConnected: false, zoneCode: null, phaseDetail: null),
        _snapshot(blockedReason: 'Not connected', queueSize: 0),
      ]) {
        final view = buildAutoGlanceView(snapshot, now: _now);
        expect(view.rows, hasLength(1));
        for (final row in view.rows) {
          expect(row.detail, isNotEmpty,
              reason:
                  'a blank row still occupies the slot but reads as broken');
        }
      }
    });
  });

  group('the row title', () {
    // The node name, so the driver can see which radio the numbers belong to.
    // It changes only on connect, disconnect or a rename — a handful of
    // templates over a session, not one per publish, so the refresh quota that
    // the fixed row count protects still holds.
    test('is the connected node', () {
      final view =
          buildAutoGlanceView(_snapshot(), now: _now, nodeName: 'Alders0n');
      expect(view.rows.single.title, 'Alders0n');
    });

    test('falls back when nothing is connected', () {
      expect(
        buildAutoGlanceView(_snapshot(), now: _now).rows.single.title,
        autoGlanceFallbackTitle,
      );
      expect(
        buildAutoGlanceView(_snapshot(), now: _now, nodeName: '')
            .rows
            .single
            .title,
        autoGlanceFallbackTitle,
      );
    });
  });

  group('the status line', () {
    String lineOf(WatchSnapshot snapshot) =>
        buildAutoGlanceView(snapshot, now: _now).rows.single.detail;

    test('carries the phase and the counters', () {
      expect(
        lineOf(_snapshot(
          txCount: 12,
          rxCount: 7,
          discoveryCount: 3,
          queueSize: 0,
        )),
        'Listening · Waiting for echoes · TX 12 · RX 7 · Disc 3',
      );
    });

    test('a queue backlog is worth the space, an empty queue is not', () {
      expect(lineOf(_snapshot(queueSize: 5)), contains('Queue 5'));
      expect(lineOf(_snapshot(queueSize: 0)), isNot(contains('Queue')));
    });

    test('falls back to the phase title alone with no detail', () {
      expect(
        lineOf(_snapshot(phaseTitle: 'Ready', phaseDetail: null)),
        startsWith('Ready · TX'),
      );
    });

    test('a live cue outranks the phase detail', () {
      expect(
        lineOf(_snapshot(
          cue: WatchHapticCue(
            id: 'cue-1',
            kind: 'failure',
            issuedAt: _now,
            message: 'Not connected',
          ),
        )),
        startsWith('Listening · Not connected'),
      );
    });

    test('a cue stops outranking it once it is no longer readable', () {
      expect(
        lineOf(_snapshot(
          cue: WatchHapticCue(
            id: 'cue-1',
            kind: 'failure',
            issuedAt: _now.subtract(WatchWire.cueReadableFor),
            message: 'Not connected',
          ),
        )),
        startsWith('Listening · Waiting for echoes'),
      );
    });

    // A disconnected radio is the one state where the phase alone can mislead,
    // so it earns the extra words.
    test('says so when the radio is disconnected', () {
      expect(lineOf(_snapshot(isConnected: false)), contains('Disconnected'));
      expect(lineOf(_snapshot()), isNot(contains('Disconnected')));
    });

    test('surfaces why the next tap would be refused', () {
      expect(
        lineOf(_snapshot(blockedReason: 'Outside zone')),
        endsWith('Outside zone'),
      );
    });
  });

  group('sessionId capture', () {
    test('is the running session', () {
      final view = buildAutoGlanceView(_snapshot(sessionId: 'abc'), now: _now);
      expect(view.sessionId, 'abc');
    });

    // Carrying an id past the end of its session would let a Stop name a run
    // that has already stopped, which is exactly what the admission guard exists
    // to catch — so do not hand it one.
    test('is null when no session is running', () {
      final view = buildAutoGlanceView(
        _snapshot(isSessionActive: false),
        now: _now,
      );
      expect(view.sessionId, isNull);
    });
  });

  group('urgencyKey', () {
    String keyOf(WatchSnapshot s) =>
        buildAutoGlanceView(s, now: _now).urgencyKey;

    // Counters move constantly during a session. If they were urgent, the floor
    // that keeps the pane inside its template quota would never apply.
    test('does not change on counters alone', () {
      expect(
        keyOf(_snapshot(txCount: 99, rxCount: 98, discoveryCount: 97)),
        keyOf(_snapshot()),
      );
    });

    test('changes when the session changes', () {
      expect(keyOf(_snapshot(sessionId: 'other')), isNot(keyOf(_snapshot())));
    });

    test('changes when the session stops', () {
      expect(
        keyOf(_snapshot(isSessionActive: false)),
        isNot(keyOf(_snapshot())),
      );
    });

    test('changes when the phase changes', () {
      expect(
        keyOf(_snapshot(phase: LiveActivityPhase.sending)),
        isNot(keyOf(_snapshot())),
      );
    });

    test('changes when the radio connects or drops', () {
      expect(keyOf(_snapshot(isConnected: false)), isNot(keyOf(_snapshot())));
    });

    test('changes when a new cue arrives', () {
      final cued = _snapshot(
        cue: WatchHapticCue(
          id: 'cue-1',
          kind: 'failure',
          issuedAt: _now,
          message: 'Could not start',
        ),
      );
      expect(keyOf(cued), isNot(keyOf(_snapshot())));
    });

    test('changes when the blocked reason changes', () {
      expect(
        keyOf(_snapshot(blockedReason: 'Not connected')),
        isNot(keyOf(_snapshot())),
      );
    });
  });

  group('fingerprint', () {
    test('is identical for identical content', () {
      expect(
        buildAutoGlanceView(_snapshot(), now: _now).fingerprint,
        buildAutoGlanceView(_snapshot(), now: _now).fingerprint,
      );
    });

    test('changes when a counter changes', () {
      expect(
        buildAutoGlanceView(_snapshot(txCount: 4), now: _now).fingerprint,
        isNot(buildAutoGlanceView(_snapshot(), now: _now).fingerprint),
      );
    });
  });
}
