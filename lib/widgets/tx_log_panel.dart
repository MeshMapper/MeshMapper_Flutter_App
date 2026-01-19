import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/log_entry.dart';

/// TX Log Panel Widget
/// Reference: TX Log section in index.html (wardrive.js)
///
/// Features:
/// - Collapsible panel with summary bar
/// - Shows count, last time, and repeat count
/// - Scrollable log entries (newest first)
/// - SNR color-coded chips for repeaters
/// - Copy to clipboard button
class TxLogPanel extends StatefulWidget {
  final List<TxLogEntry> entries;
  final VoidCallback? onCopy;

  const TxLogPanel({
    super.key,
    required this.entries,
    this.onCopy,
  });

  @override
  State<TxLogPanel> createState() => _TxLogPanelState();
}

class _TxLogPanelState extends State<TxLogPanel> {
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
    final heardCount = lastEntry?.events.length ?? 0;

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
                          'TX LOG',
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
                          'Pings: $count',
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

                  // Repeat count chip
                  if (lastEntry != null) ...[
                    const SizedBox(width: 12),
                    Text(
                      heardCount == 0
                          ? '0 Repeats'
                          : heardCount == 1
                              ? '1 Repeat'
                              : '$heardCount Repeats',
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: heardCount > 0 ? Colors.grey.shade300 : Colors.grey.shade500,
                      ),
                    ),
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
                          'No pings logged yet',
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

  Widget _buildLogEntry(BuildContext context, TxLogEntry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Timestamp and location
          Row(
            children: [
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
              Expanded(
                child: Text(
                  entry.locationString,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.grey.shade400,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),

          // Repeater chips
          if (entry.events.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 4,
              children: entry.events.map((event) {
                return _buildSnrChip(context, event);
              }).toList(),
            ),
          ] else ...[
            const SizedBox(height: 4),
            Text(
              'None',
              style: TextStyle(
                fontSize: 11,
                color: Colors.grey.shade500,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Build SNR chip matching status bar theme
  Widget _buildSnrChip(BuildContext context, RxEvent event) {
    Color chipColor;

    switch (event.severity) {
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
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            event.repeaterId,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: chipColor,
              fontFamily: 'monospace',
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '${event.snr.toStringAsFixed(2)} dB',
            style: TextStyle(
              fontSize: 11,
              color: chipColor.withValues(alpha: 0.9),
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  void _copyToClipboard(BuildContext context) {
    final csv = _generateCsv();
    Clipboard.setData(ClipboardData(text: csv));

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('TX log copied to clipboard'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  String _generateCsv() {
    final buffer = StringBuffer();
    buffer.writeln('timestamp,latitude,longitude,power,events');

    for (final entry in widget.entries) {
      buffer.writeln(entry.toCsv());
    }

    return buffer.toString();
  }
}
