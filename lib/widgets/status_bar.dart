import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/connection_state.dart';
import '../providers/app_state_provider.dart';
import '../utils/compact_count.dart';
import '../utils/distance_formatter.dart';
import '../utils/ping_colors.dart';

/// What the status bar's shared Trace/Scope slot shows.
enum StatusBarSlot { trace, scope, hidden }

/// The one slot Trace and Scope share. Trace mode and scope discovery never
/// run together (scope discovery only follows a Passive or Hybrid discovery),
/// so one chip is enough: Trace while Trace is the session's mode, else Scope
/// while scope discovery can run or once this session has counted a scope,
/// else nothing. Each count lives on in [PingStats] across a swap.
StatusBarSlot statusBarSharedSlot({
  required bool targetedMode,
  required bool scopeDiscoveryOn,
  required int scopeCount,
}) {
  if (targetedMode) return StatusBarSlot.trace;
  if (scopeDiscoveryOn || scopeCount > 0) return StatusBarSlot.scope;
  return StatusBarSlot.hidden;
}

// Chip spacing, kept tight so five chips and the region chip fit a 375 pt
// phone with 4-digit counts. The vertical padding sets the tap height and is
// left alone.
const double _chipPadH = 5;
const double _chipPadV = 4;
const double _chipIconGap = 2;
const double _chipGap = 5;

/// Status bar showing GPS, connection, and queue status
class StatusBar extends StatefulWidget {
  const StatusBar({super.key});

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
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
          // GPS region indicator (chip style)
          _buildGpsRegionChip(context, appState),

          const SizedBox(width: _chipGap),

          // Stats summary. Takes the rest of the row and, when the chips
          // still do not fit (large Accessibility text, a very narrow
          // screen), scales the whole group down rather than clip a chip.
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: _buildStatsIndicator(context, appState),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Show info popup as bottom sheet
  void _showInfoPopup(BuildContext context, String id) {
    final appState = context.read<AppStateProvider>();
    final (title, description, icon, color) =
        _getPopupContent(context, id, appState);

    showModalBottomSheet(
      context: context,
      useSafeArea: true,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => Padding(
        padding: EdgeInsets.fromLTRB(
            20, 20, 20, 20 + MediaQuery.of(context).viewPadding.bottom),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.grey.shade400,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            // Content
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, size: 24, color: color),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: color,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade600,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  /// Get content for the popup based on ID
  (String, String, IconData, Color) _getPopupContent(
      BuildContext context, String id, AppStateProvider appState) {
    switch (id) {
      case 'gps':
        if (appState.offlineMode) {
          return (
            'Offline Mode Active',
            'Pings are saved locally. Zone detection is paused until you go back online.',
            Icons.flight,
            Colors.grey
          );
        }
        if (appState.inZone == true && appState.zoneCode != null) {
          if (!appState.isConnected) {
            return (
              '${appState.displayZoneName ?? appState.shortZoneCode} Zone',
              'You\'re in an authorized zone. Connect to a device to start wardriving.',
              Icons.flight,
              Colors.grey
            );
          }
          // Region veto comes first: a flood-disabled region reports 0 TX slots,
          // which would otherwise read as "zone full" (red) instead of a
          // deliberate regional setting (blue).
          if (appState.floodDisabled) {
            return (
              '${appState.displayZoneName ?? appState.shortZoneCode} Zone',
              'Your regional admin has turned off flood traffic here, so Active and Hybrid modes are unavailable. The zone is not full. Passive and Trace modes still work.',
              Icons.flight,
              Colors.blue
            );
          }
          if (!appState.txAllowed) {
            return (
              '${appState.displayZoneName ?? appState.shortZoneCode} Zone',
              'You\'re in an authorized zone. However, the zone is at Active Wardrive capacity. You can still wardrive, but only Passive mode works.',
              Icons.flight,
              Colors.red
            );
          }
          return (
            '${appState.displayZoneName ?? appState.shortZoneCode} Zone',
            'You\'re in an active zone with ${appState.zoneSlotsAvailable ?? "?"} TX slots available. Ready to wardrive!',
            Icons.flight,
            Colors.green
          );
        }
        if (appState.inZone == false) {
          final nearest = appState.nearestZoneName ?? 'Unknown';
          final distKm = appState.nearestZoneDistanceKm;
          final dist = distKm != null
              ? formatKilometers(distKm,
                  isImperial: appState.preferences.isImperial)
              : '?';
          return (
            'Outside Coverage Area',
            'Nearest zone is $nearest, $dist away. Enter a zone to start wardriving.',
            Icons.flight,
            Colors.orange
          );
        }
        return (
          'Locating...',
          'Acquiring GPS signal and checking your zone status.',
          Icons.gps_not_fixed,
          Colors.blue
        );

      case 'tx':
        return (
          'TX Packets',
          'TX packets that have been sent out. These are messages to the #wardriving channel.',
          Icons.arrow_upward,
          PingColors.txSuccess
        );

      case 'rx':
        return (
          'RX Packets',
          'RX packets that we have heard from the mesh. These were not initiated by us.',
          Icons.arrow_downward,
          PingColors.rx
        );

      case 'disc':
        return (
          'Discovery Requests',
          'Discovery requests we have heard a response for.',
          Icons.radar,
          PingColors.discSuccess
        );

      case 'trace':
        return (
          'Trace Responses',
          'Trace path requests that received a response from the target repeater.',
          Icons.route,
          PingColors.traceSuccess
        );

      case 'scope':
        return (
          'Scopes',
          'Repeaters that answered a scope request this session, one per answer, as listed under SCP in the Log tab. '
              'Scope discovery asks the strongest repeaters a Passive or Hybrid discovery found which scopes they carry.',
          Icons.travel_explore,
          PingColors.scopesFor(Theme.of(context).brightness)
        );

      case 'upload':
        return (
          'Uploaded',
          'Pings sent to MeshMapper servers. Your data helps build the community coverage map!',
          Icons.cloud_done,
          Colors.teal
        );

      default:
        return ('Info', '', Icons.info, Colors.grey);
    }
  }

  Widget _buildGpsRegionChip(BuildContext context, AppStateProvider appState) {
    IconData icon;
    Color color;
    String text;

    // Offline mode: show greyed out with "-"
    if (appState.offlineMode) {
      icon = Icons.flight;
      color = Colors.grey;
      text = '-';
      return _buildStatChip(
          icon: icon,
          value: text,
          color: color,
          onTap: () => _showInfoPopup(context, 'gps'));
    }

    // Show GPS region (e.g., "YOW") when locked and inside a zone
    switch (appState.gpsStatus) {
      case GpsStatus.locked:
        // Check if we're in a zone and have zone code from API
        if (appState.inZone == true && appState.zoneCode != null) {
          icon = Icons.flight;
          color = appState.isConnected
              ? (appState.floodDisabled
                  ? Colors.blue // Region veto: passive only, not an error
                  : appState.txAllowed
                      ? Colors.green
                      : Colors.red)
              : Colors
                  .grey; // Grey when not connected, red when zone is at TX capacity
          text = appState.shortZoneCode!;
        } else if (appState.inZone == false) {
          // GPS locked but outside any zone
          icon = Icons.flight;
          color = Colors.orange;
          text = '—';
        } else {
          // GPS locked but zone not checked yet
          icon = Icons.flight;
          color = Colors.green;
          text = '...';
        }
        break;
      case GpsStatus.searching:
        icon = Icons.gps_not_fixed;
        color = Colors.orange;
        text = 'GPS...';
        break;
      case GpsStatus.outsideGeofence:
        // Note: This state is no longer set - zone validation is handled by API
        // Falls through to same display as locked outside zone
        icon = Icons.flight;
        color = Colors.orange;
        text = '—';
        break;
      case GpsStatus.disabled:
        icon = Icons.location_disabled;
        color = Colors.grey;
        text = 'OFF';
        break;
      case GpsStatus.permissionDenied:
        icon = Icons.location_disabled;
        color = Colors.red;
        text = '!';
        break;
    }

    return _buildStatChip(
        icon: icon,
        value: text,
        color: color,
        onTap: () => _showInfoPopup(context, 'gps'));
  }

  Widget _buildStatsIndicator(BuildContext context, AppStateProvider appState) {
    final stats = appState.pingStats;
    final slot = statusBarSharedSlot(
      targetedMode: appState.autoMode == AutoMode.targeted,
      scopeDiscoveryOn: appState.scopeDiscoveryActive,
      scopeCount: stats.scopeCount,
    );
    return Row(
      key: const ValueKey('status-bar-stats'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // TX count chip (animated)
        _AnimatedStatChip(
          icon: Icons.arrow_upward,
          value: stats.txCount,
          color: PingColors.txSuccess,
          onTap: () => _showInfoPopup(context, 'tx'),
        ),

        const SizedBox(width: _chipGap),

        // RX count chip (animated)
        _AnimatedStatChip(
          icon: Icons.arrow_downward,
          value: stats.rxCount,
          color: PingColors.rx,
          onTap: () => _showInfoPopup(context, 'rx'),
        ),

        const SizedBox(width: _chipGap),

        // DISC count chip (animated)
        _AnimatedStatChip(
          icon: Icons.radar,
          value: stats.discCount,
          color: PingColors.discSuccess,
          onTap: () => _showInfoPopup(context, 'disc'),
        ),

        // Shared Trace / Scope slot. Keyed per kind so a swap starts a fresh
        // chip instead of animating one count into the other.
        if (slot == StatusBarSlot.trace) ...[
          const SizedBox(width: _chipGap),
          _AnimatedStatChip(
            key: const ValueKey('status-bar-trace'),
            icon: Icons.route,
            value: stats.traceCount,
            color: PingColors.traceSuccess,
            onTap: () => _showInfoPopup(context, 'trace'),
          ),
        ] else if (slot == StatusBarSlot.scope) ...[
          const SizedBox(width: _chipGap),
          _AnimatedStatChip(
            key: const ValueKey('status-bar-scope'),
            icon: Icons.travel_explore,
            value: stats.scopeCount,
            color: PingColors.scopesFor(Theme.of(context).brightness),
            onTap: () => _showInfoPopup(context, 'scope'),
          ),
        ],

        const SizedBox(width: _chipGap),

        // Uploaded count chip (animated)
        _AnimatedStatChip(
          icon: Icons.cloud_done,
          value: stats.successfulUploads,
          color: Colors.teal[400]!,
          onTap: () => _showInfoPopup(context, 'upload'),
        ),
      ],
    );
  }

  Widget _buildStatChip({
    required IconData icon,
    required String value,
    required Color color,
    VoidCallback? onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: _chipPadH, vertical: _chipPadV),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withValues(alpha: 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: color),
            const SizedBox(width: _chipIconGap),
            Text(
              value,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Animated stat chip that bounces and highlights when value increments.
/// [value] stays the raw count so the increment check is exact; only the
/// text is shortened (`formatCompactCount`).
class _AnimatedStatChip extends StatefulWidget {
  final IconData icon;
  final int value;
  final Color color;
  final VoidCallback? onTap;

  const _AnimatedStatChip({
    super.key,
    required this.icon,
    required this.value,
    required this.color,
    this.onTap,
  });

  @override
  State<_AnimatedStatChip> createState() => _AnimatedStatChipState();
}

class _AnimatedStatChipState extends State<_AnimatedStatChip>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _highlightAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );

    _scaleAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.15), weight: 40),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 1.0), weight: 60),
    ]).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));

    _highlightAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.15, end: 0.5), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 0.5, end: 0.15), weight: 70),
    ]).animate(_controller);
  }

  @override
  void didUpdateWidget(_AnimatedStatChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Trigger animation only on increment
    if (widget.value > oldWidget.value) {
      _controller.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: widget.onTap,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return Transform.scale(
            scale: _scaleAnimation.value,
            child: Container(
              padding: const EdgeInsets.symmetric(
                  horizontal: _chipPadH, vertical: _chipPadV),
              decoration: BoxDecoration(
                color:
                    widget.color.withValues(alpha: _highlightAnimation.value),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: widget.color.withValues(alpha: 0.4)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, size: 14, color: widget.color),
                  const SizedBox(width: _chipIconGap),
                  Text(
                    formatCompactCount(widget.value),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: widget.color,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
