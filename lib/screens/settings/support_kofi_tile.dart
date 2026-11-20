import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// Ko-fi donation row at the bottom of the Settings tab.
///
/// The caller hides it on iOS: external donation links break Apple
/// guideline 3.1.1. Android and web show it.
class SupportKofiTile extends StatelessWidget {
  const SupportKofiTile({super.key});

  static const kofiUrl = 'https://ko-fi.com/mralders0n';

  /// Ko-fi's brand coral.
  static const kofiColor = Color(0xFFFF5E5B);

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.coffee, color: kofiColor),
      title: const Text('Support MeshMapper on Ko-fi'),
      subtitle: const Text('Help cover servers and development'),
      trailing: const Icon(Icons.open_in_new, size: 20),
      onTap: () async {
        try {
          await launchUrl(Uri.parse(kofiUrl),
              mode: LaunchMode.externalApplication);
        } catch (e) {
          debugPrint('[SETTINGS] Failed to launch Ko-fi: $e');
        }
      },
    );
  }
}
