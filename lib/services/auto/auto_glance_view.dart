import '../live_activity/live_activity_models.dart';
import '../watch/watch_models.dart';

class AutoGlanceView {
  const AutoGlanceView({
    required this.rows,
    required this.sessionId,
    required this.fingerprint,
    required this.urgencyKey,
  });

  final List<AutoGlanceRow> rows;
  final String? sessionId;
  final String fingerprint;
  final String urgencyKey;
}

class AutoGlanceRow {
  const AutoGlanceRow({required this.title, required this.detail});

  final String title;
  final String detail;
}

const String autoGlanceFallbackTitle = 'MeshMapper';
const String autoGlanceTemplateId = 'meshmapper-glance';
const String autoGlanceMapTemplateId = 'meshmapper-glance-map';
const String autoGlanceToggleActionId = 'meshmapper-glance-toggle';
const String autoGlanceTitle = '';

AutoGlanceView buildAutoGlanceView(
  WatchSnapshot snapshot, {
  required DateTime now,
  String? nodeName,
}) {
  final core = snapshot.core;
  final controls = snapshot.controls;

  final title = (nodeName == null || nodeName.isEmpty)
      ? autoGlanceFallbackTitle
      : nodeName;

  final rows = <AutoGlanceRow>[
    AutoGlanceRow(
      title: title,
      detail: <String>[
        _sessionDetail(snapshot, now: now),
        _trafficDetail(core),
        if (!core.isConnected) 'Disconnected',
        if (controls.blockedReason case final reason?
            when reason.isNotEmpty && core.isConnected)
          reason,
      ].join(' · '),
    ),
  ];

  final cue = snapshot.cue;
  return AutoGlanceView(
    rows: rows,
    sessionId: controls.isSessionActive ? core.sessionId : null,
    fingerprint: rows.map((row) => '${row.title}=${row.detail}').join('|'),
    urgencyKey: <String>[
      core.sessionId,
      controls.isSessionActive.toString(),
      core.phase.wireValue,
      core.isConnected.toString(),
      if (cue != null && cue.isPresentableAt(now)) cue.id else '',
      controls.blockedReason ?? '',
    ].join('|'),
  );
}

String _sessionDetail(WatchSnapshot snapshot, {required DateTime now}) {
  final core = snapshot.core;
  final cue = snapshot.cue;
  final message = cue != null && cue.isPresentableAt(now) ? cue.message : null;
  final detail = message ?? core.phaseDetail;
  if (detail == null || detail.isEmpty) return core.phaseTitle;
  return '${core.phaseTitle} · $detail';
}

String _trafficDetail(LiveActivitySnapshot core) {
  final parts = <String>[
    'TX ${core.txCount}',
    'RX ${core.rxCount}',
    'Disc ${core.discoveryCount}',
  ];
  if (core.queueSize > 0) parts.add('Queue ${core.queueSize}');
  return parts.join(' · ');
}
