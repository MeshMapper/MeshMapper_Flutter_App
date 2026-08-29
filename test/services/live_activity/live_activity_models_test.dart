import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';

void main() {
  test('serializes the compact ActivityKit snapshot contract', () {
    final updatedAt = DateTime.utc(2026, 7, 14, 18);
    final phaseEndsAt = updatedAt.add(const Duration(seconds: 7));
    final snapshot = LiveActivitySnapshot(
      sessionId: 'session-1',
      mode: 'Hybrid',
      phase: LiveActivityPhase.listening,
      phaseTitle: 'Listening…',
      phaseDetail: 'Waiting for repeater echoes',
      phaseEndsAt: phaseEndsAt,
      isConnected: true,
      zoneCode: 'JKG',
      txCount: 42,
      rxCount: 318,
      discoveryCount: 8,
      traceCount: 0,
      queueSize: 2,
      repeaters: const [
        LiveActivityRepeater(
          id: 'A6',
          name: 'Huskvarna',
          snr: 12.4,
        ),
      ],
      totalHeardCount: 3,
      repeatersAreCurrent: true,
      updatedAt: updatedAt,
    );

    expect(snapshot.toMap(), {
      'sessionId': 'session-1',
      'mode': 'Hybrid',
      'phase': 'listening',
      'phaseTitle': 'Listening…',
      'phaseDetail': 'Waiting for repeater echoes',
      'phaseEndsAt': phaseEndsAt.millisecondsSinceEpoch,
      'isConnected': true,
      'zoneCode': 'JKG',
      'showRepeaterNames': true,
      'txCount': 42,
      'rxCount': 318,
      'discoveryCount': 8,
      'traceCount': 0,
      'queueSize': 2,
      'repeaters': [
        {
          'id': 'A6',
          'name': 'Huskvarna',
          'snr': 12.4,
        },
      ],
      'totalHeardCount': 3,
      'repeatersAreCurrent': true,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
    });
  });

  test('urgency key changes for phase deadlines but not counters', () {
    final now = DateTime.utc(2026, 7, 14, 18);

    LiveActivitySnapshot make({
      int rxCount = 1,
      DateTime? phaseEndsAt,
    }) {
      return LiveActivitySnapshot(
        sessionId: 'session-1',
        mode: 'Active',
        phase: LiveActivityPhase.waiting,
        phaseTitle: 'Next ping',
        phaseEndsAt: phaseEndsAt ?? now.add(const Duration(seconds: 30)),
        isConnected: true,
        txCount: 1,
        rxCount: rxCount,
        discoveryCount: 0,
        traceCount: 0,
        queueSize: 0,
        repeaters: const [],
        totalHeardCount: 0,
        repeatersAreCurrent: false,
        updatedAt: now,
      );
    }

    expect(make(rxCount: 1).urgencyKey, make(rxCount: 2).urgencyKey);
    expect(
      make().urgencyKey,
      isNot(make(phaseEndsAt: now.add(const Duration(seconds: 15))).urgencyKey),
    );

    // A deadline that shifts by milliseconds is not news, and must not buy a
    // trip past the non-urgent throttle. The phone's powerlog measured 720
    // Live Activity updates across a 90-minute walk — one every 7.5 s, 116 of
    // them less than a second apart — against Apple Fitness's 2 in the same
    // window, because this key carried the deadline at millisecond resolution.
    //
    // Nothing visible is lost: the widget renders the deadline through
    // `Text(timerInterval:)` and `ProgressView(timerInterval:)`, which show
    // whole seconds.
    expect(
      make(phaseEndsAt: now).urgencyKey,
      make(phaseEndsAt: now.add(const Duration(milliseconds: 120))).urgencyKey,
    );
    // Rounding, not truncation, so the boundary is not a cliff either way.
    expect(
      make(phaseEndsAt: now).urgencyKey,
      make(phaseEndsAt: now.subtract(const Duration(milliseconds: 120)))
          .urgencyKey,
    );
    // A whole second still counts as news.
    expect(
      make(phaseEndsAt: now).urgencyKey,
      isNot(make(phaseEndsAt: now.add(const Duration(seconds: 1))).urgencyKey),
    );
  });

  test('normalizes non-finite repeater values before encoding', () {
    const repeater = LiveActivityRepeater(
      id: 'A6',
      snr: double.nan,
    );

    expect(repeater.toMap()['snr'], 0.0);
  });
}
