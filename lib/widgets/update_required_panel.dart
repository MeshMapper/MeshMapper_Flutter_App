import 'package:flutter/material.dart';

import '../utils/store_links.dart';

/// Replaces the connection error card when the server refused this build as
/// out of date. The button opens the store the app was installed from.
class UpdateRequiredPanel extends StatelessWidget {
  final AppUpdateRequirement requirement;
  final ValueChanged<StoreLink> onUpdate;
  final VoidCallback onBack;

  const UpdateRequiredPanel({
    super.key,
    required this.requirement,
    required this.onUpdate,
    required this.onBack,
  });

  static const String title = 'Update MeshMapper to continue';
  static const String body =
      'This version of the app is out of date, update the MeshMapper app on '
      'your phone to keep wardriving here.';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: EdgeInsets.all(isLandscape ? 16 : 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.system_update,
                size: isLandscape ? 48 : 64,
                color: Colors.orange,
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: 8),
              Text(
                requirement.versionLine,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: Colors.grey,
                  fontSize: 11,
                ),
              ),
              SizedBox(height: isLandscape ? 12 : 24),
              ElevatedButton.icon(
                onPressed: () => onUpdate(requirement.link),
                icon: const Icon(Icons.open_in_new),
                label: Text(requirement.link.label),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: onBack,
                child: const Text('Back'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
