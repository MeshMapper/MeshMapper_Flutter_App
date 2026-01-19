import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../providers/app_state_provider.dart';

/// Log screen with tabs for TX Log, RX Log, and User Errors
class LogScreen extends StatefulWidget {
  const LogScreen({super.key});

  @override
  State<LogScreen> createState() => _LogScreenState();
}

class _LogScreenState extends State<LogScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Logs'),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            onPressed: () => _copyCurrentTabToCsv(context, appState),
            tooltip: 'Copy CSV',
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => _confirmClearLogs(context, appState),
            tooltip: 'Clear all logs',
          ),
        ],
      ),
      body: Column(
        children: [
          // Secondary bar with tabs (full width)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(child: _buildTabChip(0, 'TX', appState.txLogEntries.length)),
                const SizedBox(width: 8),
                Expanded(child: _buildTabChip(1, 'RX', appState.rxLogEntries.length)),
                const SizedBox(width: 8),
                Expanded(child: _buildTabChip(2, 'Errors', appState.errorLogEntries.length, isError: true)),
              ],
            ),
          ),
          // Tab content
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _TxLogTab(entries: appState.txLogEntries),
                _RxLogTab(entries: appState.rxLogEntries),
                _ErrorLogTab(entries: appState.errorLogEntries),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build a tab chip that matches StatusBar chip styling
  Widget _buildTabChip(int index, String label, int count, {bool isError = false}) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: () {
        _tabController.animateTo(index);
        setState(() {});
      },
      child: AnimatedBuilder(
        animation: _tabController,
        builder: (context, child) {
          final isCurrentlySelected = _tabController.index == index;
          final currentColor = isCurrentlySelected
              ? (isError ? Colors.red : theme.colorScheme.primary)
              : theme.colorScheme.onSurfaceVariant;

          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: currentColor.withValues(alpha: isCurrentlySelected ? 0.15 : 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: currentColor.withValues(alpha: isCurrentlySelected ? 0.4 : 0.2),
              ),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isCurrentlySelected ? FontWeight.w600 : FontWeight.w500,
                    color: currentColor,
                  ),
                ),
                if (count > 0) ...[
                  const SizedBox(width: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(
                      color: currentColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      count > 99 ? '99+' : count.toString(),
                      style: const TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  void _copyCurrentTabToCsv(BuildContext context, AppStateProvider appState) {
    final currentTab = _tabController.index;

    switch (currentTab) {
      case 0: // TX Log
        _copyTxLogToCsv(context, appState.txLogEntries);
        break;
      case 1: // RX Log
        _copyRxLogToCsv(context, appState.rxLogEntries);
        break;
      case 2: // Error Log
        _copyErrorLogToCsv(context, appState.errorLogEntries);
        break;
    }
  }

  void _copyTxLogToCsv(BuildContext context, List<TxLogEntry> entries) {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No TX log entries to copy'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('timestamp,latitude,longitude,power,events');
    for (final entry in entries) {
      buffer.writeln(entry.toCsv());
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('TX log copied to clipboard'), duration: Duration(seconds: 2)),
    );
  }

  void _copyRxLogToCsv(BuildContext context, List<RxLogEntry> entries) {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No RX log entries to copy'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('timestamp,repeater_id,snr,rssi,path_length,header,latitude,longitude');
    for (final entry in entries) {
      buffer.writeln(entry.toCsv());
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('RX log copied to clipboard'), duration: Duration(seconds: 2)),
    );
  }

  void _copyErrorLogToCsv(BuildContext context, List<UserErrorEntry> entries) {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No error log entries to copy'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('timestamp,severity,message');
    for (final entry in entries) {
      buffer.writeln(entry.toCsv());
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Error log copied to clipboard'), duration: Duration(seconds: 2)),
    );
  }

  void _confirmClearLogs(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All Logs?'),
        content: const Text('This will clear TX, RX, and error logs.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearLogs();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }
}

/// TX Log Tab
class _TxLogTab extends StatelessWidget {
  final List<TxLogEntry> entries;

  const _TxLogTab({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.upload_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('No TX pings logged yet', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        // Most recent first (no reverse needed - entries already in chronological order)
        final entry = entries[entries.length - 1 - index];
        return _buildTxEntry(context, entry);
      },
    );
  }

  Widget _buildTxEntry(BuildContext context, TxLogEntry entry) {
    final appState = context.read<AppStateProvider>();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () {
          // Navigate to map and show this location
          // Main scaffold will handle switching to map tab
          appState.navigateToMapCoordinates(entry.latitude, entry.longitude);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: Time and Power
            Row(
              children: [
                // Time badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade800,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    entry.timeString,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      color: Colors.grey.shade300,
                    ),
                  ),
                ),
                const Spacer(),
                // Power indicator
                Text(
                  '${entry.power} dBm',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade500,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Location
            Row(
              children: [
                Icon(Icons.location_on, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 4),
                Text(
                  entry.locationString,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade400,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),

            // Repeaters section
            if (entry.events.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: entry.events.map((event) => _buildRepeaterChip(context, event)).toList(),
              ),
            ] else ...[
              const SizedBox(height: 8),
              Text(
                'No repeaters heard',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ],
        ),
      ),
        ),
    );
  }

  /// Build repeater chip with SNR and RSSI (status bar theme style)
  Widget _buildRepeaterChip(BuildContext context, RxEvent event) {
    Color snrColor;
    switch (event.severity) {
      case SnrSeverity.poor:
        snrColor = Colors.red;
      case SnrSeverity.fair:
        snrColor = Colors.orange;
      case SnrSeverity.good:
        snrColor = Colors.green;
    }

    // RSSI color based on signal strength
    Color rssiColor;
    if (event.rssi >= -70) {
      rssiColor = Colors.green;
    } else if (event.rssi >= -100) {
      rssiColor = Colors.orange;
    } else {
      rssiColor = Colors.red;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade700),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Repeater ID
          Text(
            event.repeaterId,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade300,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 8),
          // SNR chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: snrColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: snrColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              '${event.snr.toStringAsFixed(1)}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: snrColor,
                fontFamily: 'monospace',
              ),
            ),
          ),
          const SizedBox(width: 4),
          // RSSI chip
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: rssiColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: rssiColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              '${event.rssi}',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: rssiColor,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// RX Log Tab
class _RxLogTab extends StatelessWidget {
  final List<RxLogEntry> entries;

  const _RxLogTab({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('No RX observations yet', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        // Most recent first (no reverse needed - entries already in chronological order)
        final entry = entries[entries.length - 1 - index];
        return _buildRxEntry(context, entry);
      },
    );
  }

  Widget _buildRxEntry(BuildContext context, RxLogEntry entry) {
    final appState = context.read<AppStateProvider>();

    Color snrColor;
    switch (entry.severity) {
      case SnrSeverity.poor:
        snrColor = Colors.red;
      case SnrSeverity.fair:
        snrColor = Colors.orange;
      case SnrSeverity.good:
        snrColor = Colors.green;
    }

    // RSSI color based on signal strength
    Color rssiColor;
    if (entry.rssi >= -70) {
      rssiColor = Colors.green; // Strong: -30 to -70 dBm
    } else if (entry.rssi >= -100) {
      rssiColor = Colors.orange; // Medium: -70 to -100 dBm
    } else {
      rssiColor = Colors.red; // Weak: -100 to -120 dBm
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () {
          // Navigate to map and show this location
          // Main scaffold will handle switching to map tab
          appState.navigateToMapCoordinates(entry.latitude, entry.longitude);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row: Time badge only
            Row(
              children: [
                // Time badge
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade800,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    entry.timeString,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      color: Colors.grey.shade300,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Repeater ID row
            Row(
              children: [
                Icon(Icons.router, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 4),
                Text(
                  entry.repeaterId,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: Colors.grey.shade300,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Location
            Row(
              children: [
                Icon(Icons.location_on, size: 14, color: Colors.grey.shade500),
                const SizedBox(width: 4),
                Text(
                  entry.locationString,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade400,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),

            // Metrics row: SNR and RSSI chips
            Row(
              children: [
                // SNR chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: snrColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: snrColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    '${entry.snr.toStringAsFixed(1)} dB',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: snrColor,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                // RSSI chip
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: rssiColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: rssiColor.withValues(alpha: 0.4)),
                  ),
                  child: Text(
                    '${entry.rssi} dBm',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: rssiColor,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
        ),
    );
  }
}

/// Error Log Tab
class _ErrorLogTab extends StatelessWidget {
  final List<UserErrorEntry> entries;

  const _ErrorLogTab({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
            SizedBox(height: 16),
            Text('No errors logged', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        // Most recent first (no reverse needed - entries already in chronological order)
        final entry = entries[entries.length - 1 - index];
        return _buildErrorEntry(context, entry);
      },
    );
  }

  Widget _buildErrorEntry(BuildContext context, UserErrorEntry entry) {
    IconData icon;
    Color color;
    switch (entry.severity) {
      case ErrorSeverity.info:
        icon = Icons.info_outline;
        color = Colors.blue;
      case ErrorSeverity.warning:
        icon = Icons.warning_amber_outlined;
        color = Colors.orange;
      case ErrorSeverity.error:
        icon = Icons.error_outline;
        color = Colors.red;
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: Icon(icon, color: color),
        title: Text(entry.message),
        subtitle: Text(
          entry.timeString,
          style: TextStyle(
            fontSize: 12,
            fontFamily: 'monospace',
            color: Colors.grey.shade500,
          ),
        ),
      ),
    );
  }
}
