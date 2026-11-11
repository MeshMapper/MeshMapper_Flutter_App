import 'package:flutter/material.dart';

/// The extra line shown under the Scope Discovery switch while the connected
/// radio's companion firmware is below the feature's floor (companion
/// firmware v1.16.0). The switch keeps working either way: the setting is
/// saved, but nothing is asked and nothing extra goes on the air until the
/// firmware catches up.
class ScopeDiscoveryFirmwareNote extends StatelessWidget {
  const ScopeDiscoveryFirmwareNote({super.key, required this.show});

  final bool show;

  @override
  Widget build(BuildContext context) {
    if (!show) return const SizedBox.shrink();
    return const Padding(
      padding: EdgeInsets.only(top: 4),
      child: Text(
        'Your radio needs firmware v1.16.0 or newer for this.',
        style: TextStyle(color: Colors.amber, fontSize: 12),
      ),
    );
  }
}
