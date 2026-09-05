import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../services/portal_account_service.dart';
import 'settings_section_card.dart';

/// The portal Overview tab, on the phone: three totals and the awards row.
///
/// Rendered only when the provider holds an overview. A null overview means
/// the server has not sent the block, and the page hides this card rather
/// than print zeros.
class AccountOverviewCard extends StatelessWidget {
  final PortalOverview overview;
  final int companionCount;

  const AccountOverviewCard({
    super.key,
    required this.overview,
    required this.companionCount,
  });

  @override
  Widget build(BuildContext context) {
    return SettingsSectionCard(title: 'Overview', children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
        child: Row(children: [
          _StatTile(value: overview.points, label: 'Points'),
          _StatTile(value: overview.grid, label: 'Grid squares'),
          _StatTile(value: companionCount, label: 'Companions'),
        ]),
      ),
      if (overview.awards.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final award in overview.awards)
                ActionChip(
                  avatar: const Icon(Icons.military_tech,
                      size: 18, color: Colors.amber),
                  label: Text(award.name),
                  onPressed: () => _showAward(context, award),
                ),
            ],
          ),
        ),
    ]);
  }

  void _showAward(BuildContext context, PortalAward award) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(children: [
          const Icon(Icons.military_tech, color: Colors.amber),
          const SizedBox(width: 8),
          Expanded(child: Text(award.name)),
        ]),
        content: Text(award.description.isEmpty
            ? 'No description yet.'
            : award.description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

/// One big number over a small label, a third of the row wide.
class _StatTile extends StatelessWidget {
  final int value;
  final String label;

  const _StatTile({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Expanded(
      child: Column(children: [
        Text(
          NumberFormat.decimalPattern().format(value),
          style: theme.textTheme.titleLarge?.copyWith(
            fontWeight: FontWeight.bold,
            color: theme.colorScheme.primary,
          ),
        ),
        const SizedBox(height: 2),
        Text(label,
            textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
      ]),
    );
  }
}

/// One linked companion: name (else label, else "Companion"), its public key,
/// and a points pill when it has any. The connected radio gets the green link.
class CompanionTile extends StatelessWidget {
  final LinkedPubkey companion;
  final bool isConnected;

  const CompanionTile({
    super.key,
    required this.companion,
    required this.isConnected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = companion.name.isNotEmpty
        ? companion.name
        : companion.label.isNotEmpty
            ? companion.label
            : 'Companion';
    return ListTile(
      leading: Icon(
        isConnected ? Icons.link : Icons.memory,
        color: isConnected ? Colors.green : null,
      ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        companion.pubkey,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const ['Menlo', 'Courier New'],
          fontSize: 10,
        ),
      ),
      trailing: companion.points > 0
          ? Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: theme.colorScheme.primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '${NumberFormat.decimalPattern().format(companion.points)} pts',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.bold,
                ),
              ),
            )
          : null,
    );
  }
}
