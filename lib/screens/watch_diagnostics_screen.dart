import 'dart:async';

import 'package:flutter/material.dart';

import '../services/watch/watch_bridge_service.dart';

/// On-device evidence for why the phone is or is not sending to Apple Watch.
///
/// The bridge remains the single source of truth so opening this route cannot
/// accidentally create a second connectivity policy that drifts from the send
/// gate it is meant to explain.
class WatchDiagnosticsScreen extends StatefulWidget {
  const WatchDiagnosticsScreen({
    super.key,
    required this.bridge,
  });

  final WatchBridgeService bridge;

  @override
  State<WatchDiagnosticsScreen> createState() => _WatchDiagnosticsScreenState();
}

class _WatchDiagnosticsScreenState extends State<WatchDiagnosticsScreen> {
  Timer? _clockTimer;
  var _secondsSinceRefresh = 0;
  var _refreshing = false;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _secondsSinceRefresh++);

      // WCSession status properties are local reads. Poll only while this
      // diagnostic is visible so reachability stays live without adding work
      // to snapshot scheduling or turning normal app use into a hot path.
      if (_secondsSinceRefresh >= 5) {
        _secondsSinceRefresh = 0;
        unawaited(widget.bridge.refreshAvailability());
      }
    });
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await widget.bridge.refreshAvailability();
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Watch Connectivity', style: TextStyle(fontSize: 18)),
        actions: [
          TextButton.icon(
            onPressed: _refreshing ? null : _refresh,
            icon: _refreshing
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      ),
      body: ValueListenableBuilder<WatchDiagnosticStatus>(
        valueListenable: widget.bridge.diagnostics,
        builder: (context, status, _) {
          final failing = status.failingSyncConditions;
          final gateDetail = status.canSync
              ? 'activated, paired, and installed are all true'
              : failing.isEmpty
                  ? 'The iOS platform gate is unavailable'
                  : 'Failing ${failing.length == 1 ? 'condition' : 'conditions'}: '
                      '${failing.join(', ')}';

          return ListView(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
            children: [
              _buildSection(context, 'Native WCSession', [
                _statusTile('supported', status.supported),
                _statusTile('paired', status.paired),
                _statusTile('installed', status.installed),
                _statusTile('reachable', status.reachable),
                _statusTile('activated', status.activated),
              ]),
              _buildSection(context, 'Dart Bridge', [
                _statusTile('canSync', status.canSync),
                ListTile(
                  leading: Icon(
                    status.canSync ? Icons.check_circle : Icons.error_outline,
                    color: status.canSync ? Colors.green : Colors.orange,
                  ),
                  title: const Text('Sync gate'),
                  subtitle: Text(gateDetail),
                ),
              ]),
              _buildSection(context, 'Delivery History', [
                ListTile(
                  leading: const Icon(Icons.send_outlined),
                  title: const Text('Last successful send'),
                  subtitle: Text(_timeSince(status.lastSuccessfulSendAt)),
                ),
                ListTile(
                  leading: const Icon(Icons.sync_alt),
                  title: const Text('Last availability change'),
                  subtitle: Text(_timeSince(status.lastAvailabilityChangedAt)),
                ),
                ListTile(
                  leading: const Icon(Icons.fact_check_outlined),
                  title: const Text('Last send outcome'),
                  subtitle: Text(switch (status.lastSendDelivered) {
                    true => 'Delivered (delivered == true)',
                    false => 'Refused (delivered != true)',
                    null => 'No send attempted this run',
                  }),
                ),
              ]),
            ],
          );
        },
      ),
    );
  }

  Widget _statusTile(String name, bool value) {
    return ListTile(
      leading: Icon(
        value ? Icons.check_circle_outline : Icons.cancel_outlined,
        color: value ? Colors.green : Colors.orange,
      ),
      title: Text(name),
      trailing: Text(value ? 'true' : 'false'),
    );
  }

  String _timeSince(DateTime? timestamp) {
    if (timestamp == null) return 'Not recorded this run';
    final elapsed = DateTime.now().difference(timestamp);
    if (elapsed.inSeconds < 5) return 'Just now';
    if (elapsed.inMinutes < 1) return '${elapsed.inSeconds}s ago';
    if (elapsed.inHours < 1) return '${elapsed.inMinutes}m ago';
    if (elapsed.inDays < 1) {
      return '${elapsed.inHours}h ${elapsed.inMinutes.remainder(60)}m ago';
    }
    return '${elapsed.inDays}d ${elapsed.inHours.remainder(24)}h ago';
  }

  Widget _buildSection(
      BuildContext context, String title, List<Widget> children) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: Theme.of(context).colorScheme.primary,
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ),
            ...children,
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}
