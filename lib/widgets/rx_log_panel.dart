import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/log_entry.dart';

/// RX Log Panel Widget (Passive Observations)
/// Reference: RX Log section in index.html (wardrive.js)
///
/// Features:
/// - Collapsible panel with summary bar
/// - Shows count, last time, last repeater, and SNR chip
/// - Scrollable log entries (newest first)
/// - SNR color-coded entries
/// - Copy to clipboard button
class RxLogPanel extends StatefulWidget {
  final List<RxLogEntry> entries;
  final VoidCallback? onCopy;

  const RxLogPanel({
    super.key,
    required this.entries,
    this.onCopy,
  });

  @override
  State<RxLogPanel> createState() => _RxLogPanelState();
}

class _RxLogPanelState extends State<RxLogPanel> {
  bool _isExpanded = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.entries.length;
    final lastEntry = count > 0 ? widget.entries.last : null;

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withOpacity(0.8),
        border: Border.all(color: Colors.grey.shade700),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Summary bar (collapsible toggle)
          InkWell(
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  // Title and stats
                  Expanded(
                    child: Row(
                      children: [
                        Text(
                          'RX LOG',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey.shade300,
                            letterSpacing: 0.5,
                          ),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          '|',
                          style: TextStyle(color: Colors.grey.shade500),
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'Obs: $count',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: Colors.grey.shade300,
                          ),
                        ),
                        if (lastEntry != null) ...[
                          const SizedBox(width: 12),
                          Text(
                            lastEntry.timeString,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.grey.shade400,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // Last repeater and SNR chip
                  if (lastEntry != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      lastEntry.repeaterId,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: Colors.grey.shade400,
                      ),
                    ),
                    const SizedBox(width: 6),
                    _buildMiniSnrChip(context, lastEntry),
                  ],

                  // Copy button
                  if (count > 0) ...[
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () {
                        widget.onCopy?.call();
                        _copyToClipboard(context);
                      },
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Text(
                          'Copy',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey.shade400,
                          ),
                        ),
                      ),
                    ),
                  ],

                  // Expand arrow
                  const SizedBox(width: 8),
                  AnimatedRotation(
                    turns: _isExpanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 20,
                      color: Colors.grey.shade400,
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Expandable log content
          if (_isExpanded)
            Container(
              decoration: BoxDecoration(
                border: Border(
                  top: BorderSide(color: Colors.grey.shade700),
                ),
              ),
              constraints: const BoxConstraints(maxHeight: 256),
              child: count == 0
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(
                        child: Text(
                          'No RX observations yet',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.grey,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: _scrollController,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      itemCount: count,
                      reverse: true, // Newest first
                      itemBuilder: (context, index) {
                        final entry = widget.entries[count - 1 - index];
                        return _buildLogEntry(context, entry);
                      },
                    ),
            ),
        ],
      ),
    );
  }

  Widget _buildLogEntry(BuildContext context, RxLogEntry entry) {
    Color chipColor;

    switch (entry.severity) {
      case SnrSeverity.poor:
        chipColor = Colors.red;
        break;
      case SnrSeverity.fair:
        chipColor = Colors.orange;
        break;
      case SnrSeverity.good:
        chipColor = Colors.green;
        break;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timestamp
          Text(
            entry.timeString,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: Colors.grey.shade300,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '|',
            style: TextStyle(color: Colors.grey.shade600),
          ),
          const SizedBox(width: 8),

          // Repeater ID chip (status bar style)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: chipColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: chipColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              entry.repeaterId,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                fontFamily: 'monospace',
                color: chipColor,
              ),
            ),
          ),

          const SizedBox(width: 8),

          // SNR value
          Text(
            '${entry.snr.toStringAsFixed(2)} dB',
            style: TextStyle(
              fontSize: 11,
              fontFamily: 'monospace',
              color: chipColor,
            ),
          ),

          const SizedBox(width: 8),

          // RSSI value
          Text(
            '${entry.rssi} dBm',
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: Colors.grey.shade500,
            ),
          ),

          const Spacer(),

          // Path length
          Text(
            'H:${entry.pathLength}',
            style: TextStyle(
              fontSize: 10,
              fontFamily: 'monospace',
              color: Colors.grey.shade500,
            ),
          ),
        ],
      ),
    );
  }

  /// Build mini SNR chip matching status bar theme
  Widget _buildMiniSnrChip(BuildContext context, RxLogEntry entry) {
    Color chipColor;

    switch (entry.severity) {
      case SnrSeverity.poor:
        chipColor = Colors.red;
        break;
      case SnrSeverity.fair:
        chipColor = Colors.orange;
        break;
      case SnrSeverity.good:
        chipColor = Colors.green;
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: chipColor.withValues(alpha: 0.4)),
      ),
      child: Text(
        '${entry.snr.toStringAsFixed(2)} dB',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: chipColor,
          fontFamily: 'monospace',
        ),
      ),
    );
  }

  void _copyToClipboard(BuildContext context) {
    final csv = _generateCsv();
    Clipboard.setData(ClipboardData(text: csv));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('RX log copied to clipboard'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _generateCsv() {
    final buffer = StringBuffer();
    buffer.writeln('timestamp,repeater_id,snr,rssi,path_length,header,latitude,longitude');

    for (final entry in widget.entries) {
      buffer.writeln(entry.toCsv());
    }

    return buffer.toString();
  }
}
