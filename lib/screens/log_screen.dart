import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/log_entry.dart';
import '../providers/app_state_provider.dart';
import '../widgets/repeater_id_chip.dart';

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
    _tabController = TabController(length: 5, vsync: this);
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
        if (mounted && _tabController.index != 4) {
          _tabController.animateTo(4); // Switch to Error tab
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
                Expanded(child: _buildTabChip(0, 'TX', appState.txLogEntries.length, isTx: true)),
                const SizedBox(width: 6),
                Expanded(child: _buildTabChip(1, 'RX', appState.rxLogEntries.length, isRx: true)),
                const SizedBox(width: 6),
                Expanded(child: _buildTabChip(2, 'DISC', appState.discLogEntries.length, isDisc: true)),
                const SizedBox(width: 6),
                Expanded(child: _buildTabChip(3, 'TRC', appState.traceLogEntries.length, isTrace: true)),
                const SizedBox(width: 6),
                Expanded(child: _buildTabChip(4, 'Err', appState.errorLogEntries.length, isError: true)),
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
                _TraceLogTab(entries: appState.traceLogEntries),
                _ErrorLogTab(entries: appState.errorLogEntries),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build a tab chip that matches StatusBar chip styling
  Widget _buildTabChip(int index, String label, int count, {bool isError = false, bool isDisc = false, bool isTx = false, bool isRx = false, bool isTrace = false}) {
    final theme = Theme.of(context);
    // Colors matching status bar chips
    const discColor = Color(0xFF7B68EE); // DISC purple
    const txColor = Colors.green;         // TX green (matches status bar)
    const rxColor = Colors.blue;          // RX blue (matches status bar)
    const traceColor = Colors.cyan;       // TRC cyan (matches noise floor chart)

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
            } else if (isTrace) {
              currentColor = traceColor;
            } else if (isTx) {
              currentColor = txColor;
            } else if (isRx) {
              currentColor = rxColor;
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
                Flexible(
                  child: Text(
                    label,
                    overflow: TextOverflow.clip,
                    softWrap: false,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isCurrentlySelected ? FontWeight.w600 : FontWeight.w500,
                      color: currentColor,
                    ),
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
      case 3: // TRC Log
        _copyTraceLogToCsv(context, appState.traceLogEntries);
        break;
      case 4: // Error Log
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

  void _copyTraceLogToCsv(BuildContext context, List<TraceLogEntry> entries) {
    if (entries.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No trace log entries to copy'), duration: Duration(seconds: 2)),
      );
      return;
    }

    final buffer = StringBuffer();
    buffer.writeln('timestamp,target_repeater,local_snr,local_rssi,remote_snr,latitude,longitude,noisefloor,success');
    for (final entry in entries) {
      buffer.writeln(entry.toCsv());
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Trace log copied to clipboard'), duration: Duration(seconds: 2)),
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
        content: const Text('This will clear TX, RX, DISC, TRC, and error logs.'),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.upload_outlined, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No TX pings logged yet', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    entry.timeString,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                const Spacer(),
                // Power indicator (watts)
                Text(
                  '${entry.power.toStringAsFixed(1)} W',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                    fontFamily: 'monospace',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Location
            Row(
              children: [
                Icon(Icons.location_on, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  entry.locationString,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                  border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                ),
                child: Column(
                  children: [
                    // Header row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 60,
                            child: Text(
                              'Node',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                color: Theme.of(context).colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Divider(height: 1, color: Theme.of(context).dividerColor),
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
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
      case null:
        snrColor = Colors.grey;
    }

    // RSSI color based on signal strength
    Color rssiColor;
    if (event.rssi == null) {
      rssiColor = Colors.grey;
    } else if (event.rssi! >= -70) {
      rssiColor = Colors.green;
    } else if (event.rssi! >= -100) {
      rssiColor = Colors.orange;
    } else {
      rssiColor = Colors.red;
    }

    return InkWell(
      onTap: () => RepeaterIdChip.showRepeaterPopup(context, event.repeaterId),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            // Repeater ID
            RepeaterIdChip(repeaterId: event.repeaterId, fontSize: 11, width: 60),
            // SNR
            Expanded(
              child: Center(
                child: _buildTxChip(event.snr?.toStringAsFixed(1) ?? '-', snrColor),
              ),
            ),
            // RSSI
            Expanded(
              child: Center(
                child: _buildTxChip(event.rssi != null ? '${event.rssi}' : '-', rssiColor),
              ),
            ),
          ],
        ),
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.download_outlined, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No RX observations yet', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
      case null:
        snrColor = Colors.grey;
    }

    // RSSI color based on signal strength
    Color rssiColor;
    if (entry.rssi == null) {
      rssiColor = Colors.grey;
    } else if (entry.rssi! >= -70) {
      rssiColor = Colors.green; // Strong: -30 to -70 dBm
    } else if (entry.rssi! >= -100) {
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
                    color: Theme.of(context).colorScheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    entry.timeString,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Location
            Row(
              children: [
                Icon(Icons.location_on, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  entry.locationString,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
              ),
              child: Column(
                children: [
                  // Header row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 60,
                          child: Text(
                            'Node',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  Divider(height: 1, color: Theme.of(context).dividerColor),
                  // Data row
                  InkWell(
                    onTap: () => RepeaterIdChip.showRepeaterPopup(context, entry.repeaterId),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      child: Row(
                        children: [
                          // Repeater ID
                          RepeaterIdChip(repeaterId: entry.repeaterId, fontSize: 11, width: 60),
                          // SNR
                          Expanded(
                            child: Center(
                              child: _buildRxChip(entry.snr?.toStringAsFixed(1) ?? '-', snrColor),
                            ),
                          ),
                          // RSSI
                          Expanded(
                            child: Center(
                              child: _buildRxChip(entry.rssi != null ? '${entry.rssi}' : '-', rssiColor),
                            ),
                          ),
                        ],
                      ),
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

/// DISC Log Tab (Discovery observations from Passive Mode)
class _DiscLogTab extends StatelessWidget {
  final List<DiscLogEntry> entries;

  const _DiscLogTab({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.radar_outlined, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text('No discovery observations yet', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            Text('Enable Passive Mode to discover nearby nodes',
                style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12)),
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
                      color: Theme.of(context).colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      entry.timeString,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Node count indicator (like power indicator in TX log)
                  Text(
                    '${entry.nodeCount} node${entry.nodeCount == 1 ? '' : 's'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Location
              Row(
                children: [
                  Icon(Icons.location_on, size: 14, color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    entry.locationString,
                    style: TextStyle(
                      fontSize: 11,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                    border: Border.all(color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      // Header row
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 70,
                              child: Text(
                                'Node',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
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
                                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: Theme.of(context).dividerColor),
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
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
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

    return InkWell(
      onTap: () => RepeaterIdChip.showRepeaterPopup(context, node.repeaterId, fullHexId: node.pubkeyHex),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            // Node ID with type
            SizedBox(
              width: 70,
              child: Row(
                children: [
                  Flexible(
                    child: RepeaterIdChip(repeaterId: node.repeaterId, fontSize: 11),
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

/// Trace Log Tab (Trace Mode results)
class _TraceLogTab extends StatelessWidget {
  final List<TraceLogEntry> entries;

  const _TraceLogTab({required this.entries});

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.gps_fixed, size: 48, color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.3)),
            const SizedBox(height: 16),
            Text(
              'No trace results yet',
              style: TextStyle(
                fontSize: 16,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Enter a repeater ID and start Trace Mode',
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: entries.length,
      itemBuilder: (context, index) {
        return _buildTraceEntry(context, entries[index]);
      },
    );
  }

  Widget _buildTraceEntry(BuildContext context, TraceLogEntry entry) {
    final colorScheme = Theme.of(context).colorScheme;
    final appState = context.read<AppStateProvider>();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: colorScheme.surfaceContainerHigh,
      child: InkWell(
        onTap: () {
          appState.navigateToMapCoordinates(entry.latitude, entry.longitude);
        },
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header row: Time and repeater ID (matching disc style)
              Row(
                children: [
                  // Time badge (neutral, matching disc)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: colorScheme.surfaceContainerHigh,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      entry.timeString,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        fontFamily: 'monospace',
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  const Spacer(),
                  // Repeater ID + success/fail text
                  Text(
                    entry.targetRepeaterId,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      fontFamily: 'monospace',
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    entry.success ? 'responded' : 'no response',
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),

              // Location
              Row(
                children: [
                  Icon(Icons.location_on, size: 14, color: colorScheme.onSurfaceVariant),
                  const SizedBox(width: 4),
                  Text(
                    entry.locationString,
                    style: TextStyle(
                      fontSize: 11,
                      color: colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                ],
              ),

              // Results table (matching disc style)
              if (entry.success) ...[
                const SizedBox(height: 10),
                Container(
                  decoration: BoxDecoration(
                    color: colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colorScheme.outline.withValues(alpha: 0.5)),
                  ),
                  child: Column(
                    children: [
                      // Header row
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 70,
                              child: Text(
                                'Node',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: colorScheme.onSurfaceVariant,
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
                                  color: colorScheme.onSurfaceVariant,
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
                                  color: colorScheme.onSurfaceVariant,
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
                                  color: colorScheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Divider(height: 1, color: Theme.of(context).dividerColor),
                      // Data row
                      _buildTraceNodeRow(context, entry),
                    ],
                  ),
                ),
              ] else ...[
                const SizedBox(height: 8),
                Text(
                  'No response',
                  style: TextStyle(
                    fontSize: 11,
                    color: colorScheme.onSurfaceVariant,
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

  /// Build the data row for a trace result (matching disc node row style)
  Widget _buildTraceNodeRow(BuildContext context, TraceLogEntry entry) {
    // RX SNR color
    final rxSnr = entry.localSnr;
    Color rxSnrColor;
    if (rxSnr == null) {
      rxSnrColor = Colors.grey;
    } else if (rxSnr <= -1) {
      rxSnrColor = Colors.red;
    } else if (rxSnr <= 5) {
      rxSnrColor = Colors.orange;
    } else {
      rxSnrColor = Colors.green;
    }

    // RSSI color
    final rssi = entry.localRssi;
    Color rssiColor;
    if (rssi == null) {
      rssiColor = Colors.grey;
    } else if (rssi >= -70) {
      rssiColor = Colors.green;
    } else if (rssi >= -100) {
      rssiColor = Colors.orange;
    } else {
      rssiColor = Colors.red;
    }

    // TX SNR color (remote)
    final txSnr = entry.remoteSnr;
    Color txSnrColor;
    if (txSnr == null) {
      txSnrColor = Colors.grey;
    } else if (txSnr <= -1) {
      txSnrColor = Colors.red;
    } else if (txSnr <= 5) {
      txSnrColor = Colors.orange;
    } else {
      txSnrColor = Colors.green;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 70,
            child: RepeaterIdChip(repeaterId: entry.targetRepeaterId, fontSize: 11),
          ),
          Expanded(
            child: Center(
              child: _buildChip(rxSnr?.toStringAsFixed(1) ?? '-', rxSnrColor),
            ),
          ),
          Expanded(
            child: Center(
              child: _buildChip(rssi != null ? '$rssi' : '-', rssiColor),
            ),
          ),
          Expanded(
            child: Center(
              child: _buildChip(txSnr?.toStringAsFixed(1) ?? '-', txSnrColor),
            ),
          ),
        ],
      ),
    );
  }

  /// Build a small colored chip for table cells (matching disc style)
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
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check_circle_outline, size: 48, color: Colors.green),
            const SizedBox(height: 16),
            Text('No errors logged', style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant)),
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
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
