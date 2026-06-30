import 'package:flutter/material.dart';

import '../utils/coverage_summary.dart';
import '../utils/distance_formatter.dart';

/// Bottom sheet showing the coverage "GRID SUMMARY" for a tapped map cell — the
/// 3×3 stat grid + the proportional bar graph with a separator line, mirroring
/// the web popup (`generateSummaryContent`, dev/index.php:13345). Deliberately
/// excludes the web's PING HISTORY list.
class CellSummarySheet extends StatelessWidget {
  /// Resolves to the aggregated summary, or null on fetch failure. The caller
  /// fetches the cell's points and computes [GridSummary] off the UI thread.
  final Future<GridSummary?> summaryFuture;
  final bool isImperial;

  /// When non-null, a minimize button is shown in the header (collapses the
  /// sheet to a pill, like the ping-focus sheets). Null = close-only.
  final VoidCallback? onMinimize;

  const CellSummarySheet({
    super.key,
    required this.summaryFuture,
    required this.isImperial,
    this.onMinimize,
  });

  // Web GRID SUMMARY palette (dev/index.php getPalette 'none').
  static const Color _bidir = Color(0xFF1E7E34);
  static const Color _tx = Color(0xFFFD7E14);
  static const Color _rx = Color(0xFF6F42C1);
  static const Color _disc = Color(0xFF17A2B8);
  static const Color _dead = Color(0xFF6C757D);
  static const Color _drop = Color(0xFFBD2130);
  static const Color _maxDistBlue = Color(0xFF007BFF);
  static const Color _snrGood = Color(0xFF1E7E34);
  static const Color _snrMedium = Color(0xFF856404);
  static const Color _snrBad = Color(0xFFBD2130);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: EdgeInsets.fromLTRB(
          20, 20, 20, 24 + MediaQuery.of(context).viewPadding.bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'GRID SUMMARY',
                  style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                      letterSpacing: 0.5),
                ),
              ),
              if (onMinimize != null)
                IconButton(
                  icon: const Icon(Icons.keyboard_arrow_down, size: 20),
                  onPressed: onMinimize,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  color: theme.colorScheme.onSurfaceVariant,
                  tooltip: 'Minimize',
                ),
              if (onMinimize != null) const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.pop(context),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ],
          ),
          const SizedBox(height: 8),
          FutureBuilder<GridSummary?>(
            future: summaryFuture,
            builder: (context, snap) {
              if (snap.connectionState != ConnectionState.done) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 32),
                  child: Center(child: CircularProgressIndicator()),
                );
              }
              final s = snap.data;
              if (s == null) return _note(context, 'Could not load coverage data.');
              if (s.total == 0) return _note(context, 'No coverage data here.');
              return _buildSummary(context, s);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSummary(BuildContext context, GridSummary s) {
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: 'Total Pings: ',
                  style: TextStyle(
                      fontSize: 12, color: theme.colorScheme.onSurfaceVariant),
                ),
                TextSpan(
                  text: '${s.total}',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            _cell(context, value: '${s.bidir}', label: 'BIDIR', color: _bidir),
            _cell(context, value: '${s.tx}', label: 'TX', color: _tx),
            _cell(context, value: '${s.rx}', label: 'RX', color: _rx),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _cell(context, value: '${s.disc}', label: 'DISC', color: _disc),
            _cell(context, value: '${s.dead}', label: 'DEAD', color: _dead),
            _cell(context, value: '${s.drop}', label: 'DROP', color: _drop),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _snrCell(context, s),
            _cell(
              context,
              value: s.maxDistMeters != null
                  ? formatCoverageDistance(s.maxDistMeters!, isImperial: isImperial)
                  : 'N/A',
              label: 'MAX DIST',
              color: _maxDistBlue,
            ),
            _cell(
              context,
              value: s.avgNoise != null ? '${s.avgNoise}' : 'N/A',
              valueSuffix: s.avgNoise != null ? ' dBm' : null,
              label: 'AVG NOISE',
            ),
          ],
        ),
        const SizedBox(height: 16),
        _barGraph(context, s),
      ],
    );
  }

  Widget _cell(
    BuildContext context, {
    required String value,
    required String label,
    Color? color,
    String? valueSuffix,
    Widget? valueWidget,
  }) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          valueWidget ??
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: value,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: color ?? theme.colorScheme.onSurface,
                      ),
                    ),
                    if (valueSuffix != null)
                      TextSpan(
                        text: valueSuffix,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurfaceVariant,
              letterSpacing: 0.3,
            ),
          ),
        ],
      ),
    );
  }

  Widget _snrCell(BuildContext context, GridSummary s) {
    final theme = Theme.of(context);
    final bucket = s.snrBucket;
    final Widget valueWidget;
    if (bucket == null) {
      valueWidget = Text(
        'N/A',
        style: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: theme.colorScheme.onSurface,
        ),
      );
    } else {
      final IconData icon;
      final Color color;
      switch (bucket) {
        case 'good':
          icon = Icons.signal_cellular_4_bar;
          color = _snrGood;
          break;
        case 'medium':
          icon = Icons.signal_cellular_alt;
          color = _snrMedium;
          break;
        default:
          icon = Icons.signal_cellular_alt_1_bar;
          color = _snrBad;
      }
      valueWidget = SizedBox(
        height: 24,
        child: Icon(icon, size: 22, color: color),
      );
    }
    return _cell(context, value: '', label: 'AVG SNR', valueWidget: valueWidget);
  }

  Widget _barGraph(BuildContext context, GridSummary s) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // Success segments first (BIDIR, DISC, TX, RX), then a separator "line",
    // then fail segments (DEAD, DROP) — flex-weighted by count (web order).
    final success = <(Color, int, String)>[
      (_bidir, s.bidir, 'BIDIR'),
      (_disc, s.disc, 'DISC/TRACE'),
      (_tx, s.tx, 'TX'),
      (_rx, s.rx, 'RX'),
    ];
    final fail = <(Color, int, String)>[
      (_dead, s.dead, 'DEAD'),
      (_drop, s.drop, 'DROP'),
    ];
    final hasSuccess = success.any((e) => e.$2 > 0);
    final hasFail = fail.any((e) => e.$2 > 0);
    if (!hasSuccess && !hasFail) return const SizedBox.shrink();

    final children = <Widget>[];
    void addSeg((Color, int, String) seg) {
      if (seg.$2 <= 0) return;
      children.add(
        Expanded(
          flex: seg.$2,
          child: Tooltip(
            message: '${seg.$3}: ${seg.$2}',
            child: Container(color: seg.$1),
          ),
        ),
      );
    }

    for (final seg in success) {
      addSeg(seg);
    }
    if (hasSuccess && hasFail) {
      children.add(Container(
        width: 2,
        color: isDark ? const Color(0xFFCCCCCC) : const Color(0xFF444444),
      ));
    }
    for (final seg in fail) {
      addSeg(seg);
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(height: 10, child: Row(children: children)),
    );
  }

  Widget _note(BuildContext context, String msg) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Center(
          child: Text(
            msg,
            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
          ),
        ),
      );
}
