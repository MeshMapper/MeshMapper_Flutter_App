import 'package:flutter/material.dart';

/// Rounded card grouping related settings tiles, with an optional header.
///
/// Folder pages whose single card would repeat the page title leave [title]
/// null; pages with several cards keep the section titles as headers.
class SettingsSectionCard extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const SettingsSectionCard({super.key, this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Card(
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (title != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Text(
                  title!,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                        fontWeight: FontWeight.bold,
                      ),
                ),
              )
            else
              const SizedBox(height: 4),
            ...children,
            const SizedBox(height: 4),
          ],
        ),
      ),
    );
  }
}

/// Amber notice shown while auto-ping has some settings locked.
///
/// Shown on the Settings tab and on every folder page that holds locked tiles.
class AutoPingLockBanner extends StatelessWidget {
  const AutoPingLockBanner({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.amber.withValues(alpha: 0.3)),
        ),
        child: const Row(
          children: [
            Icon(Icons.lock, size: 16, color: Colors.amber),
            SizedBox(width: 8),
            Text(
              'Some settings locked during auto-ping',
              style: TextStyle(fontSize: 12, color: Colors.amber),
            ),
          ],
        ),
      ),
    );
  }
}
