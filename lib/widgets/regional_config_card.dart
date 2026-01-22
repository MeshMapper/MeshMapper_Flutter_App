import 'package:flutter/material.dart';

/// Card displaying regional configuration (zone + channels)
/// Shows the current zone and RX channels available for monitoring
class RegionalConfigCard extends StatelessWidget {
  final String? zoneName;
  final String? zoneCode;
  final List<String> channels;

  const RegionalConfigCard({
    super.key,
    this.zoneName,
    this.zoneCode,
    this.channels = const [],
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Icon(Icons.public, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 8),
                Text(
                  'Regional Configuration',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const Divider(height: 24),

            // Zone info
            _buildInfoRow(context, Icons.location_on, 'Zone',
              zoneName ?? 'Not configured'),
            if (zoneCode != null) ...[
              const SizedBox(height: 8),
              _buildInfoRow(context, Icons.flight, 'IATA', zoneCode!),
            ],
            const SizedBox(height: 12),

            // Channels header
            _buildInfoRow(context, Icons.tag, 'RX Channels', null),
            const SizedBox(height: 8),

            // Channel chips
            Padding(
              padding: const EdgeInsets.only(left: 26),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  _buildChannelChip(context, 'Public', isDefault: true),
                  _buildChannelChip(context, '#wardriving', isDefault: true),
                  ...channels.map((c) => _buildChannelChip(context, c)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(BuildContext context, IconData icon, String label, String? value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: Colors.grey),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        if (value != null) ...[
          const SizedBox(width: 8),
          Expanded(
            child: Text(value, style: TextStyle(
              color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
            )),
          ),
        ],
      ],
    );
  }

  Widget _buildChannelChip(BuildContext context, String name, {bool isDefault = false}) {
    // Public channel doesn't use # prefix
    final displayName = name == 'Public' ? name : (name.startsWith('#') ? name : '#$name');
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
        displayName,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          // Use onPrimaryContainer for proper contrast on primaryContainer background
          color: isDefault ? Colors.grey : Theme.of(context).colorScheme.onPrimaryContainer,
        ),
      ),
    );
  }
}
