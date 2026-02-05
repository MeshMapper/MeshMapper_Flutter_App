import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/noise_floor_session.dart';
import '../providers/app_state_provider.dart';
import '../widgets/noise_floor_chart.dart';

/// Screen showing noise floor session history and graph popup
class GraphScreen extends StatelessWidget {
  const GraphScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final sessions = appState.storedNoiseFloorSessions;
    final currentSession = appState.currentNoiseFloorSession;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Noise Floor History'),
        automaticallyImplyLeading: false,
        actions: [
          if (sessions.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              onPressed: () => _confirmClearSessions(context, appState),
              tooltip: 'Clear all sessions',
            ),
        ],
      ),
      body: _buildBody(context, currentSession, sessions),
    );
  }

  Widget _buildBody(
    BuildContext context,
    NoiseFloorSession? currentSession,
    List<NoiseFloorSession> sessions,
  ) {
    // Show empty state if no sessions
    if (currentSession == null && sessions.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.show_chart,
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
                'Enable Active or Passive Mode to start recording noise floor data.',
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
        // Current active session (if recording)
        if (currentSession != null) ...[
          _SessionListTile(
            session: currentSession,
            isActive: true,
            onTap: () => _openFullScreenGraph(context, currentSession),
          ),
          if (sessions.isNotEmpty) const Divider(),
        ],

        // Stored sessions (last 10)
        ...sessions.map((session) => _SessionListTile(
              session: session,
              isActive: false,
              onTap: () => _openFullScreenGraph(context, session),
            )),
      ],
    );
  }

  void _openFullScreenGraph(BuildContext context, NoiseFloorSession session) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => _FullScreenGraphPage(session: session),
      ),
    );
  }

  void _confirmClearSessions(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Sessions?'),
        content: const Text('This will delete all saved noise floor session graphs. The current active session will not be affected.'),
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

/// Full-screen graph page with pinch-to-zoom and pan
class _FullScreenGraphPage extends StatelessWidget {
  final NoiseFloorSession session;

  const _FullScreenGraphPage({required this.session});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(session.modeDisplay),
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          // Reset zoom button
          IconButton(
            icon: const Icon(Icons.zoom_out_map),
            tooltip: 'Reset zoom',
            onPressed: () {
              // The chart handles this internally via key reset
              _resetKey.currentState?.resetZoom();
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // Session info header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    session.mode == 'active' ? Icons.send : Icons.hearing,
                    size: 20,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_formatDateTime(session.startTime)} | '
                      '${session.durationDisplay} | '
                      '${session.samples.length} samples, '
                      '${session.markers.length} events',
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
            // Hint text
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
            // Chart
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 16, 8),
                child: InteractiveNoiseFloorChart(
                  key: _resetKey,
                  session: session,
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

final GlobalKey<InteractiveNoiseFloorChartState> _resetKey = GlobalKey();

/// List tile showing a session summary
class _SessionListTile extends StatelessWidget {
  final NoiseFloorSession session;
  final bool isActive;
  final VoidCallback onTap;

  const _SessionListTile({
    required this.session,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        session.mode == 'active' ? Icons.send : Icons.hearing,
        color: isActive ? Colors.green : null,
      ),
      title: Text(session.modeDisplay),
      subtitle: Text(
        '${_formatDateTime(session.startTime)} | ${session.durationDisplay} | '
        '${session.samples.length} samples, ${session.markers.length} events',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
      trailing: isActive
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.green.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.green),
              ),
              child: const Text(
                'LIVE',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.green,
                ),
              ),
            )
          : const Icon(Icons.chevron_right),
      onTap: onTap,
    );
  }

  String _formatDateTime(DateTime dt) {
    return '${dt.month}/${dt.day} ${dt.hour}:${dt.minute.toString().padLeft(2, '0')}';
  }
}
