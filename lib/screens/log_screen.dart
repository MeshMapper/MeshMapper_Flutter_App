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
    _tabController = TabController(length: 4, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    // Auto-switch to Error tab when requested
    if (appState.requestErrorLogSwitch) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _tabController.index != 3) {
          _tabController.animateTo(3); // Switch to Error tab
          setState(() {});
        }
        appState.clearErrorLogSwitchRequest();
      });
    }

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
                Expanded(child: _buildTabChip(2, 'DISC', appState.discLogEntries.length, isDisc: true)),
                const SizedBox(width: 8),
                Expanded(child: _buildTabChip(3, 'Errors', appState.errorLogEntries.length, isError: true)),
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
                _DiscLogTab(entries: appState.discLogEntries),
                _ErrorLogTab(entries: appState.errorLogEntries),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build a tab chip that matches StatusBar chip styling
  Widget _buildTabChip(int index, String label, int count, {bool isError = false, bool isDisc = false}) {
    final theme = Theme.of(context);
    // Medium slate blue/purple for DISC tab
    const discColor = Color(0xFF7B68EE);

    return GestureDetector(
      onTap: () {
        _tabController.animateTo(index);
        setState(() {});
      },
      child: AnimatedBuilder(
        animation: _tabController,
        builder: (context, child) {
          final isCurrentlySelected = _tabController.index == index;
          Color currentColor;
          if (isCurrentlySelected) {
            if (isError) {
              currentColor = Colors.red;
            } else if (isDisc) {
              currentColor = discColor;
            } else {
              currentColor = theme.colorScheme.primary;
            }
          } else {
            currentColor = theme.colorScheme.onSurfaceVariant;
          }

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
      case 2: // DISC Log
        _copyDiscLogToCsv(context, appState.discLogEntries);
        break;
      case 3: // Error Log
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

  void _copyDiscLogToCsv(BuildContext context, List<DiscLogEntry> entries) {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No DISC log entries to copy'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('timestamp,latitude,longitude,noisefloor,node_count,nodes');
    for (final entry in entries) {
      buffer.writeln(entry.toCsv());
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('DISC log copied to clipboard'), duration: Duration(seconds: 2)),
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
        content: const Text('This will clear TX, RX, DISC, and error logs.'),
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

            // Repeaters table
            if (entry.events.isNotEmpty) ...[
              const SizedBox(height: 10),
              Container(
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey.shade700),
                ),
                child: Column(
                  children: [
                    // Header row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 50,
                            child: Text(
                              'Node',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'SNR',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ),
                          Expanded(
                            child: Text(
                              'RSSI',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Colors.grey.shade500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: Colors.grey.shade700),
                    // Data rows
                    ...entry.events.map((event) => _buildRepeaterRow(context, event)),
                  ],
                ),
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

  /// Build a table row for a repeater event
  Widget _buildRepeaterRow(BuildContext context, RxEvent event) {
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

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          // Repeater ID
          SizedBox(
            width: 50,
            child: Text(
              event.repeaterId,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: Colors.grey.shade300,
              ),
            ),
          ),
          // SNR
          Expanded(
            child: Center(
              child: _buildTxChip(event.snr.toStringAsFixed(1), snrColor),
            ),
          ),
          // RSSI
          Expanded(
            child: Center(
              child: _buildTxChip('${event.rssi}', rssiColor),
            ),
          ),
        ],
      ),
    );
  }

  /// Build a small colored chip for TX table cells
  Widget _buildTxChip(String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          fontFamily: 'monospace',
        ),
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

            // Repeater table (single row)
            Container(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade700),
              ),
              child: Column(
                children: [
                  // Header row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 50,
                          child: Text(
                            'Node',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'SNR',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ),
                        Expanded(
                          child: Text(
                            'RSSI',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Colors.grey.shade700),
                  // Data row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      children: [
                        // Repeater ID
                        SizedBox(
                          width: 50,
                          child: Text(
                            entry.repeaterId,
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'monospace',
                              color: Colors.grey.shade300,
                            ),
                          ),
                        ),
                        // SNR
                        Expanded(
                          child: Center(
                            child: _buildRxChip(entry.snr.toStringAsFixed(1), snrColor),
                          ),
                        ),
                        // RSSI
                        Expanded(
                          child: Center(
                            child: _buildRxChip('${entry.rssi}', rssiColor),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
        ),
    );
  }

  /// Build a small colored chip for RX table cells
  Widget _buildRxChip(String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          fontFamily: 'monospace',
        ),
      ),
    );
  }
}

/// DISC Log Tab (Discovery observations from RX Auto mode)
class _DiscLogTab extends StatelessWidget {
  final List<DiscLogEntry> entries;

  const _DiscLogTab({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.radar_outlined, size: 48, color: Colors.grey),
            SizedBox(height: 16),
            Text('No discovery observations yet', style: TextStyle(color: Colors.grey)),
            SizedBox(height: 8),
            Text('Enable RX Auto mode to discover nearby nodes',
                style: TextStyle(color: Colors.grey, fontSize: 12)),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        final entry = entries[index]; // Already sorted most recent first
        return _buildDiscEntry(context, entry);
      },
    );
  }

  Widget _buildDiscEntry(BuildContext context, DiscLogEntry entry) {
    final appState = context.read<AppStateProvider>();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () {
          // Navigate to map and show this location
          appState.navigateToMapCoordinates(entry.latitude, entry.longitude);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: Time and node count (matching TX log style)
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
                  // Node count indicator (like power indicator in TX log)
                  Text(
                    '${entry.nodeCount} node${entry.nodeCount == 1 ? '' : 's'}',
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

              // Nodes table
              if (entry.discoveredNodes.isNotEmpty) ...[
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade700),
                  ),
                  child: Column(
                    children: [
                      // Header row
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 50,
                              child: Text(
                                'Node',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'RX SNR',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'RX RSSI',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Text(
                                'TX SNR',
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: Colors.grey.shade700),
                      // Data rows
                      ...entry.discoveredNodes.map((node) => _buildNodeRow(context, node)),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  'No nodes discovered',
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

  /// Build a table row for a discovered node
  Widget _buildNodeRow(BuildContext context, DiscoveredNodeEntry node) {
    // Color for RX SNR (what we received)
    Color rxSnrColor;
    switch (node.severity) {
      case SnrSeverity.poor:
        rxSnrColor = Colors.red;
      case SnrSeverity.fair:
        rxSnrColor = Colors.orange;
      case SnrSeverity.good:
        rxSnrColor = Colors.green;
    }

    // TX SNR color (what they received from us)
    Color txSnrColor;
    if (node.remoteSnr <= -1) {
      txSnrColor = Colors.red;
    } else if (node.remoteSnr <= 5) {
      txSnrColor = Colors.orange;
    } else {
      txSnrColor = Colors.green;
    }

    // RSSI color based on signal strength
    Color rssiColor;
    if (node.localRssi >= -70) {
      rssiColor = Colors.green;
    } else if (node.localRssi >= -100) {
      rssiColor = Colors.orange;
    } else {
      rssiColor = Colors.red;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          // Node ID with type
          SizedBox(
            width: 50,
            child: Row(
              children: [
                Text(
                  node.repeaterId,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                    color: Colors.grey.shade300,
                  ),
                ),
                Text(
                  node.nodeTypeLabel,
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF7B68EE),
                  ),
                ),
              ],
            ),
          ),
          // RX SNR
          Expanded(
            child: Center(
              child: _buildChip(node.localSnr.toStringAsFixed(1), rxSnrColor),
            ),
          ),
          // RSSI
          Expanded(
            child: Center(
              child: _buildChip('${node.localRssi}', rssiColor),
            ),
          ),
          // TX SNR
          Expanded(
            child: Center(
              child: _buildChip(node.remoteSnr.toStringAsFixed(1), txSnrColor),
            ),
          ),
        ],
      ),
    );
  }

  /// Build a small colored chip for table cells
  Widget _buildChip(String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        value,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
          fontFamily: 'monospace',
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
