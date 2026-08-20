import '../watch/watch_color.dart';

/// High-level phase shared by native glance surfaces.
///
/// [idle] is watch-only: the Live Activity builder still uses its session-only
/// resolver directly, while the always-present watch projects that resolver's
/// no-session fallback to this value.
enum LiveActivityPhase {
  idle,
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
        LiveActivityPhase.idle => 'idle',
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
        buildPreflightUrgencyKey(
          sessionId: sessionId,
          mode: mode,
          phase: phase,
          phaseTitle: phaseTitle,
          phaseDetail: phaseDetail,
          phaseEndsAt: phaseEndsAt,
          phaseDurationMs: phaseDurationMs,
          isConnected: isConnected,
          zoneCode: zoneCode,
        ),
        pingColor?.r ?? '',
        pingColor?.g ?? '',
        pingColor?.b ?? '',
      ].join('|');

  /// Every urgent field that can be resolved without walking a ping history.
  ///
  /// [LiveActivityService] needs to decide whether a flush may wait *before* it
  /// builds a snapshot, and building one resolves the latest ping colour by
  /// scanning the full TX, RX, discovery and trace logs. Sharing this formatter
  /// with [urgencyKey] keeps the cheap preflight and the eventual decision from
  /// drifting on what counts as news.
  ///
  /// The ping colour is the one urgent field left out, because it is the
  /// expensive one. In practice a ping outcome moves the phase with it, so this
  /// key changes anyway; a colour that somehow moved alone is held for at most
  /// one throttle interval rather than being dropped.
  static String buildPreflightUrgencyKey({
    required String sessionId,
    required String mode,
    required LiveActivityPhase phase,
    required String phaseTitle,
    required String? phaseDetail,
    required DateTime? phaseEndsAt,
    required int? phaseDurationMs,
    required bool isConnected,
    required String? zoneCode,
  }) =>
      [
        sessionId,
        mode,
        phase.wireValue,
        phaseTitle,
        phaseDetail ?? '',
        // Seconds, not milliseconds. **At millisecond resolution any
        // recomputation of the deadline reads as news** and forces an immediate
        // send past the 15 s non-urgent throttle, because the key differs even
        // when the phase has not changed.
        //
        // Measured on the 2026-08-16 walk, from the phone's powerlog
        // (`PLApplicationAgent_EventPoint_LiveActivityUpdates`): 720 updates in
        // 90 minutes, one every 7.5 s, against Apple Fitness's 2 in the same
        // window. 69 % of the gaps were under the throttle, and 116 of them
        // were **under one second** — which no real phase change can produce,
        // and which the 200 ms debounce should already have absorbed.
        //
        // A deadline that moves by milliseconds is not something a wearer can
        // see: the widget renders it with `Text(timerInterval:)` and
        // `ProgressView(timerInterval:)`, both of which show whole seconds. So
        // rounding here cannot lose anything the surface could display, while a
        // genuine phase change moves the deadline by seconds at minimum and
        // still bypasses the throttle exactly as intended.
        phaseEndsAt == null
            ? 0
            : (phaseEndsAt.millisecondsSinceEpoch / 1000).round(),
        phaseDurationMs ?? 0,
        isConnected,
        zoneCode ?? '',
      ].join('|');
}
