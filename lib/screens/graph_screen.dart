import 'dart:async';

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
        toolbarHeight: 40,
        title:
            const Text('Noise Floor History', style: TextStyle(fontSize: 18)),
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
            onTap: () =>
                _openFullScreenGraph(context, currentSession, isLive: true),
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
            'This will delete all saved noise floor session graphs. The current active session will not be affected.'),
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
          // Session ended while viewing
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
          // Reset zoom button
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
            // Session info header
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
