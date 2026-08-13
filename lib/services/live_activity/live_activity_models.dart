import '../watch/watch_color.dart';

/// High-level phase shown by the iOS Live Activity.
enum LiveActivityPhase {
  active,
  starting,
  sending,
  discovering,
  tracing,
  listening,
  listeningDiscovery,
  listeningTrace,
  waiting,
  waitingDiscovery,
  waitingTrace,
  cooldown,
  skipped,
  stopping,
  waitingForGps,
  pausedOutsideZone,
  disconnected,
  txBlocked,
}

extension LiveActivityPhaseWireValue on LiveActivityPhase {
  String get wireValue => switch (this) {
        LiveActivityPhase.active => 'active',
        LiveActivityPhase.starting => 'starting',
        LiveActivityPhase.sending => 'sending',
        LiveActivityPhase.discovering => 'discovering',
        LiveActivityPhase.tracing => 'tracing',
        LiveActivityPhase.listening => 'listening',
        LiveActivityPhase.listeningDiscovery => 'listening_discovery',
        LiveActivityPhase.listeningTrace => 'listening_trace',
        LiveActivityPhase.waiting => 'waiting',
        LiveActivityPhase.waitingDiscovery => 'waiting_discovery',
        LiveActivityPhase.waitingTrace => 'waiting_trace',
        LiveActivityPhase.cooldown => 'cooldown',
        LiveActivityPhase.skipped => 'skipped',
        LiveActivityPhase.stopping => 'stopping',
        LiveActivityPhase.waitingForGps => 'waiting_for_gps',
        LiveActivityPhase.pausedOutsideZone => 'paused_outside_zone',
        LiveActivityPhase.disconnected => 'disconnected',
        LiveActivityPhase.txBlocked => 'tx_blocked',
      };
}

/// Compact repeater observation included in a Live Activity update.
class LiveActivityRepeater {
  const LiveActivityRepeater({
    required this.id,
    required this.snr,
    this.name,
    this.typeColor,
    this.snrColor,
  });

  final String id;
  final String? name;
  final double snr;
  final WatchColor? typeColor;
  final WatchColor? snrColor;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'snr': snr.isFinite ? snr : 0.0,
        if (typeColor != null) 'typeColor': typeColor!.toMap(),
        if (snrColor != null) 'snrColor': snrColor!.toMap(),
      };
}

/// Complete, serializable snapshot rendered by ActivityKit.
class LiveActivitySnapshot {
  const LiveActivitySnapshot({
    required this.sessionId,
    required this.mode,
    required this.phase,
    required this.phaseTitle,
    required this.isConnected,
    required this.txCount,
    required this.rxCount,
    required this.discoveryCount,
    required this.traceCount,
    required this.queueSize,
    required this.repeaters,
    required this.totalHeardCount,
    required this.repeatersAreCurrent,
    required this.updatedAt,
    this.phaseDetail,
    this.phaseEndsAt,
    this.phaseDurationMs,
    this.pingColor,
    this.zoneCode,
  });

  final String sessionId;
  final String mode;
  final LiveActivityPhase phase;
  final String phaseTitle;
  final String? phaseDetail;
  final DateTime? phaseEndsAt;
  final int? phaseDurationMs;
  final WatchColor? pingColor;
  final bool isConnected;
  final String? zoneCode;
  final int txCount;
  final int rxCount;
  final int discoveryCount;
  final int traceCount;
  final int queueSize;
  final List<LiveActivityRepeater> repeaters;
  final int totalHeardCount;
  final bool repeatersAreCurrent;
  final DateTime updatedAt;

  Map<String, Object?> toMap() => {
        'sessionId': sessionId,
        'mode': mode,
        'phase': phase.wireValue,
        'phaseTitle': phaseTitle,
        'phaseDetail': phaseDetail,
        'phaseEndsAt': phaseEndsAt?.millisecondsSinceEpoch,
        if (phaseDurationMs != null) 'phaseDurationMs': phaseDurationMs,
        if (pingColor != null) 'pingColor': pingColor!.toMap(),
        'isConnected': isConnected,
        'zoneCode': zoneCode,
        'txCount': txCount,
        'rxCount': rxCount,
        'discoveryCount': discoveryCount,
        'traceCount': traceCount,
        'queueSize': queueSize,
        'repeaters': repeaters.map((repeater) => repeater.toMap()).toList(),
        'totalHeardCount': totalHeardCount,
        'repeatersAreCurrent': repeatersAreCurrent,
        'updatedAt': updatedAt.millisecondsSinceEpoch,
      };

  /// Fields that must bypass the normal update throttle.
  String get urgencyKey => [
        sessionId,
        mode,
        phase.wireValue,
        phaseTitle,
        phaseDetail ?? '',
        phaseEndsAt?.millisecondsSinceEpoch ?? 0,
        phaseDurationMs ?? 0,
        pingColor?.r ?? '',
        pingColor?.g ?? '',
        pingColor?.b ?? '',
        isConnected,
        zoneCode ?? '',
      ].join('|');
}
