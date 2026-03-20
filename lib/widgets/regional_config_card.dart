import 'package:flutter/material.dart';

/// Card displaying regional configuration (zone + channels)
/// Shows the current zone and RX channels available for monitoring
class RegionalConfigCard extends StatelessWidget {
  final String? zoneName;
  final String? zoneCode;
  final List<String> channels;
  final String? scope;
  final bool isOfflineMode;
  final bool compact;

  const RegionalConfigCard({
    super.key,
    this.zoneName,
    this.zoneCode,
    this.channels = const [],
    this.scope,
    this.isOfflineMode = false,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    if (compact) {
      return _buildCompact(context);
    }

    // When offline mode is enabled, show "-" for zone fields
    final displayZoneName = isOfflineMode ? '-' : (zoneName ?? 'Not configured');
    final displayZoneCode = isOfflineMode ? '-' : zoneCode;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  isOfflineMode ? Icons.cloud_off : Icons.public,
                  color: isOfflineMode ? Colors.orange : Theme.of(context).colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text(
                  'Regional Configuration',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (isOfflineMode) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'OFFLINE',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const Divider(height: 24),

            // Zone info
            _buildInfoRow(context, Icons.location_on, 'Zone', displayZoneName,
                isOffline: isOfflineMode),
            const SizedBox(height: 8),
            _buildInfoRow(context, Icons.flight, 'IATA', displayZoneCode ?? '-',
                isOffline: isOfflineMode),
            const SizedBox(height: 12),

            // Scope
            _buildInfoRow(
              context,
              Icons.filter_alt,
              'Scope',
              isOfflineMode ? '-' : (scope ?? 'Global'),
              isOffline: isOfflineMode,
            ),
            const SizedBox(height: 12),

            // Channels header
            _buildInfoRow(context, Icons.tag, 'RX Channels', null),
            const SizedBox(height: 8),

            // Channel chips - show Public and #wardriving when offline
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _buildChannelChip(context, 'Public', isDefault: true),
                  _buildChannelChip(context, '#wardriving', isDefault: true),
                  if (!isOfflineMode)
                    ...channels.map((c) => _buildChannelChip(context, c)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact mode: "Regional Settings" header, scope row, channel chips
  Widget _buildCompact(BuildContext context) {
    final displayZone = isOfflineMode ? null : zoneName;
    final displayScope = isOfflineMode ? '-' : (scope ?? 'Global');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(
                  Icons.public,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 8),
                Text(
                  'Regional Settings',
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (displayZone != null)
                  Text(
                    displayZone,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),

            // Scope row
            _buildCompactRow(context, 'Scope', [
              _buildChannelChip(context, displayScope, isDefault: true),
            ]),
            const SizedBox(height: 8),

            // Channels row
            _buildCompactRow(context, 'Channels', [
              _buildChannelChip(context, 'Public', isDefault: true),
              _buildChannelChip(context, '#wardriving', isDefault: true),
              if (!isOfflineMode)
                ...channels.map((c) => _buildChannelChip(context, c)),
            ]),
          ],
        ),
      ),
    );
  }

  /// Compact labeled row: small label on left, chips on right
  Widget _buildCompactRow(BuildContext context, String label, List<Widget> chips) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 70,
          child: Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: chips,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(BuildContext context, IconData icon, String label, String? value,
      {bool isOffline = false}) {
    return Row(
      children: [
        Icon(icon, size: 18, color: isOffline ? Colors.orange : Colors.grey),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        if (value != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(value, style: TextStyle(
              color: isOffline
                  ? Colors.orange.shade700
                  : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            )),
          ),
        ],
      ],
    );
  }

  Widget _buildChannelChip(BuildContext context, String name, {bool isDefault = false}) {
    // Public channel doesn't use # prefix; scope/plain values pass through as-is
    final displayName = name == 'Public' ? name : (name.startsWith('#') ? name : '#$name');
    // If it doesn't look like a channel name, show raw value (e.g. scope "Global")
    final isChannel = name.startsWith('#') || name == 'Public';
    final label = isChannel ? displayName : name;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: isDefault
            ? Colors.grey.withValues(alpha: 0.15)
            : Theme.of(context).colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDefault
              ? Colors.grey.withValues(alpha: 0.4)
              : Theme.of(context).colorScheme.primary.withValues(alpha: 0.4),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          color: isDefault ? Colors.grey : Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
