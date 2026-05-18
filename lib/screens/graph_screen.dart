import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/noise_floor_session.dart';
import '../providers/app_state_provider.dart';
import '../widgets/noise_floor_chart.dart';

/// Screen showing session history with options to view on map or noise floor graph
class GraphScreen extends StatelessWidget {
  const GraphScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final sessions = appState.storedNoiseFloorSessions;
    final currentSession = appState.currentNoiseFloorSession;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Session History', style: TextStyle(fontSize: 18)),
        automaticallyImplyLeading: false,
        actions: [
          if (sessions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20),
              onPressed: () => _confirmClearSessions(context, appState),
              tooltip: 'Clear all sessions',
            ),
        ],
      ),
      body: _buildBody(context, appState, currentSession, sessions),
    );
  }

  Widget _buildBody(
    BuildContext context,
    AppStateProvider appState,
    NoiseFloorSession? currentSession,
    List<NoiseFloorSession> sessions,
  ) {
    if (currentSession == null && sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.history,
                size: 64,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(height: 16),
              Text(
                'No sessions recorded yet',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Enable Active or Passive Mode to start recording session data.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      children: [
        if (currentSession != null) ...[
          _SessionCard(
            session: currentSession,
            isActive: true,
            onViewGraph: () =>
                _openFullScreenGraph(context, currentSession, isLive: true),
            onViewMap: null,
          ),
          if (sessions.isNotEmpty) const SizedBox(height: 4),
        ],
        ...sessions.map((session) => _SessionCard(
              session: session,
              isActive: false,
              onViewGraph: () => _openFullScreenGraph(context, session),
              onViewMap: _sessionHasGpsMarkers(session)
                  ? () => appState.viewHistorySessionOnMap(session)
                  : null,
            )),
      ],
    );
  }

  bool _sessionHasGpsMarkers(NoiseFloorSession session) {
    return session.markers
        .any((m) => m.latitude != null && m.longitude != null);
  }

  void _openFullScreenGraph(BuildContext context, NoiseFloorSession session,
      {bool isLive = false}) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) =>
            _FullScreenGraphPage(session: session, isLive: isLive),
      ),
    );
  }

  void _confirmClearSessions(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Sessions?'),
        content: const Text(
            'This will delete all saved session history. The current active session will not be affected.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearStoredNoiseFloorSessions();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

/// Card showing a session with action buttons
class _SessionCard extends StatelessWidget {
  final NoiseFloorSession session;
  final bool isActive;
  final VoidCallback onViewGraph;
  final VoidCallback? onViewMap;

  const _SessionCard({
    required this.session,
    required this.isActive,
    required this.onViewGraph,
    required this.onViewMap,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: mode icon, mode name, live badge, time
            Row(
              children: [
                Icon(
                  _modeIcon,
                  size: 20,
                  color: isActive ? Colors.green : colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  session.modeDisplay,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                if (isActive) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.green.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.green),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: Colors.green,
                      ),
                    ),
                  ),
                ],
                const Spacer(),
                Text(
                  _formatDateTime(session.startTime),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // Stats row
            Text(
              '${session.durationDisplay} duration | '
              '${session.samples.length} samples | '
              '${session.markers.length} events',
              style: TextStyle(
                fontSize: 12,
                color: colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            // Action buttons row
            Row(
              children: [
                Expanded(
                  child: _ActionButton(
                    icon: Icons.map_outlined,
                    label: 'View on Map',
                    onPressed: onViewMap,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _ActionButton(
                    icon: Icons.show_chart,
                    label: 'Noise Floor',
                    onPressed: onViewGraph,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  IconData get _modeIcon => switch (session.mode) {
        'active' => Icons.send,
        'hybrid' => Icons.swap_horiz,
        'targeted' => Icons.track_changes,
        _ => Icons.hearing,
      };

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}

/// Styled action button for session cards
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, style: const TextStyle(fontSize: 12)),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        minimumSize: const Size(0, 34),
        foregroundColor:
            onPressed != null ? colorScheme.primary : colorScheme.outline,
        side: BorderSide(
          color: onPressed != null
              ? colorScheme.outline
              : colorScheme.outline.withValues(alpha: 0.4),
        ),
      ),
    );
  }
}

/// Full-screen graph page with pinch-to-zoom and pan
class _FullScreenGraphPage extends StatefulWidget {
  final NoiseFloorSession session;
  final bool isLive;

  const _FullScreenGraphPage({required this.session, this.isLive = false});

  @override
  State<_FullScreenGraphPage> createState() => _FullScreenGraphPageState();
}

class _FullScreenGraphPageState extends State<_FullScreenGraphPage> {
  final GlobalKey<InteractiveNoiseFloorChartState> _chartKey = GlobalKey();
  Timer? _liveTimer;
  late NoiseFloorSession _session;
  bool _sessionEnded = false;

  @override
  void initState() {
    super.initState();
    _session = widget.session;
    if (widget.isLive) {
      _liveTimer = Timer.periodic(const Duration(seconds: 2), (_) {
        final current =
            context.read<AppStateProvider>().currentNoiseFloorSession;
        if (current != null) {
          setState(() {
            _session = current;
          });
        } else {
          _liveTimer?.cancel();
          _liveTimer = null;
          setState(() {
            _sessionEnded = true;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
  }

  bool get _showLiveBadge => widget.isLive && !_sessionEnded;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_session.modeDisplay),
            if (_showLiveBadge) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.green),
                ),
                child: const Text(
                  'LIVE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: Colors.green,
                  ),
                ),
              ),
            ],
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.zoom_out_map),
            tooltip: 'Reset zoom',
            onPressed: () {
              _chartKey.currentState?.resetZoom();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _session.mode == 'active' ? Icons.send : Icons.hearing,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_formatDateTime(_session.startTime)} | '
                      '${_session.durationDisplay} | '
                      '${_session.samples.length} samples, '
                      '${_session.markers.length} events',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Text(
                'Pinch to zoom, drag to pan',
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
                child: InteractiveNoiseFloorChart(
                  key: _chartKey,
                  session: _session,
                  isLive: _showLiveBadge,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
