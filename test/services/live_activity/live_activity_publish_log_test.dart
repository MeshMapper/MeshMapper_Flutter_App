import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_models.dart';
import 'package:mesh_mapper/services/live_activity/live_activity_service.dart';

LiveActivitySnapshot _snapshot({
  required LiveActivityPhase phase,
  List<LiveActivityRepeater> repeaters = const [],
  bool current = true,
  int? noiseFloorDbm,
}) =>
    LiveActivitySnapshot(
      sessionId: 'session-1',
      mode: 'Hybrid',
      phase: phase,
      phaseTitle: 'Next ping',
      isConnected: true,
      txCount: 4,
      rxCount: 4,
      discoveryCount: 5,
      traceCount: 0,
      queueSize: 0,
      repeaters: repeaters,
      totalHeardCount: repeaters.length,
      repeatersAreCurrent: current,
      noiseFloorDbm: noiseFloorDbm,
      updatedAt: DateTime.utc(2026, 9, 5, 10, 3, 35),
    );

void main() {
  test('the publish log line names phase, urgency, rows and the gap', () {
    final line = LiveActivityService.describePublish(
      _snapshot(
        phase: LiveActivityPhase.waiting,
        repeaters: const [
          LiveActivityRepeater(id: '7B2EF0', snr: 9.5),
          LiveActivityRepeater(id: '4E3192', snr: 7.8),
          LiveActivityRepeater(id: 'CA1AE', snr: -0.8),
        ],
        noiseFloorDbm: -94,
      ),
      urgent: true,
      sinceLast: const Duration(milliseconds: 12300),
    );

    expect(
      line,
      'Published waiting (urgent) rows=7B2EF0:9.5,4E3192:7.8,CA1AE:-0.8 '
      'current=true noise=-94 +12.3s',
    );
  });

  test('the first publish has no gap and empty rows say none', () {
    final line = LiveActivityService.describePublish(
      _snapshot(phase: LiveActivityPhase.listening, current: false),
      urgent: false,
      sinceLast: null,
    );

    expect(line, 'Published listening rows=none current=false noise=?');
  });
}
