import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import 'tx_log_panel.dart';
import 'rx_log_panel.dart';

/// Stats panel showing TX/RX counts and success rates
class StatsPanel extends StatelessWidget {
  const StatsPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final stats = appState.pingStats;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Text(
            'Statistics',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 16),

          // TX/RX grid
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  context,
                  icon: Icons.arrow_upward,
                  label: 'TX',
                  value: '${stats.txCount}',
                  color: Colors.green,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  context,
                  icon: Icons.arrow_downward,
                  label: 'RX',
                  value: '${stats.rxCount}',
                  color: Colors.blue,
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Upload stats
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  context,
                  icon: Icons.cloud_done,
                  label: 'Uploaded',
                  value: '${stats.successfulUploads}',
                  color: Colors.teal,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildStatCard(
                  context,
                  icon: Icons.cloud_queue,
                  label: 'Queued',
                  value: '${appState.queueSize}',
                  color: Colors.orange,
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // Success rate
          if (stats.successfulUploads + stats.failedUploads > 0) ...[
            Text(
              'Upload Success Rate',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            LinearProgressIndicator(
              value: stats.successRate,
              backgroundColor: Colors.red.shade100,
              valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
            ),
            const SizedBox(height: 4),
            Text(
              '${(stats.successRate * 100).toStringAsFixed(1)}%',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],

          // Clear buttons
          Row(
            children: [
              Expanded(
                child: TextButton.icon(
                  onPressed: () => appState.clearPings(),
                  icon: const Icon(Icons.delete_outline, size: 18),
                  label: const Text('Clear Markers', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextButton.icon(
                  onPressed: () => appState.clearLogs(),
                  icon: const Icon(Icons.delete_sweep, size: 18),
                  label: const Text('Clear Logs', style: TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 16),

          // TX Log Panel
          TxLogPanel(entries: appState.txLogEntries),

          const SizedBox(height: 12),

          // RX Log Panel
          RxLogPanel(entries: appState.rxLogEntries),
        ],
      ),
    );
  }

  /// Build stat card matching status bar chip theme
  Widget _buildStatCard(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: 4),
          Text(
            value,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: color,
                ),
          ),
        ],
      ),
    );
  }
}
