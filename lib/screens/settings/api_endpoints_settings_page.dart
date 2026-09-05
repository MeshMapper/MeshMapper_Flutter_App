import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../utils/debug_logger_io.dart';
import '../../widgets/app_toast.dart';
import 'settings_section_card.dart';

/// Settings folder: API Endpoints.
class ApiEndpointsSettingsPage extends StatelessWidget {
  const ApiEndpointsSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final prefs = appState.preferences;
    final isAutoMode = appState.autoPingEnabled;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('API Endpoints', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          if (isAutoMode) const AutoPingLockBanner(),
          const SettingsSectionCard(title: 'MeshMapper', children: [
            ListTile(
              leading: Icon(Icons.cloud_done, color: Colors.green),
              title: Text('MeshMapper API'),
              subtitle: Text('Always active'),
            ),
          ]),
          SettingsSectionCard(title: 'Custom Endpoint', children: [
            SwitchListTile(
              secondary: const Icon(Icons.api),
              title: const Text('Custom API Endpoint'),
              subtitle: Text(prefs.customApiEnabled
                  ? (prefs.customApiUrl ?? 'Not configured')
                  : 'Forward pings to a third-party server'),
              value: prefs.customApiEnabled,
              onChanged: isAutoMode
                  ? null
                  : (value) {
                      if (value) {
                        _showCustomApiDisclaimer(context, appState);
                      } else {
                        appState.updatePreferences(
                            prefs.copyWith(customApiEnabled: false));
                      }
                    },
            ),
            if (prefs.customApiEnabled) ...[
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('Endpoint URL'),
                subtitle: Text(prefs.customApiUrl ?? 'Not set'),
                trailing: const Icon(Icons.chevron_right),
                onTap: isAutoMode
                    ? null
                    : () => _showCustomApiUrlDialog(context, appState),
              ),
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('API Key'),
                subtitle: Text(prefs.customApiKey != null
                    ? '\u2022\u2022\u2022\u2022\u2022\u2022\u2022\u2022'
                    : 'Not set'),
                trailing: const Icon(Icons.chevron_right),
                onTap: isAutoMode
                    ? null
                    : () => _showCustomApiKeyDialog(context, appState),
              ),
              SwitchListTile(
                secondary: const SizedBox(width: 24),
                title: const Text('Include Contact Key'),
                subtitle:
                    const Text('Share device public key prefix with endpoint'),
                value: prefs.customApiIncludeContact,
                onChanged: isAutoMode
                    ? null
                    : (value) {
                        appState.updatePreferences(
                            prefs.copyWith(customApiIncludeContact: value));
                      },
              ),
              ListTile(
                leading: const Icon(Icons.content_paste),
                title: const Text('Import from Clipboard'),
                subtitle: const Text('Paste a meshmapper:// config link'),
                onTap: isAutoMode
                    ? null
                    : () => _importCustomApiFromClipboard(context, appState),
              ),
            ],
          ]),
        ],
      ),
    );
  }

  void _showCustomApiDisclaimer(
      BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber, size: 24, color: Colors.amber),
            SizedBox(width: 8),
            Flexible(child: Text('Third-Party Data Sharing')),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enabling this feature will forward your wardriving data to a '
              'third-party server that is not operated by MeshMapper.',
            ),
            SizedBox(height: 12),
            Text(
              'The following data will be shared:\n'
              '\u2022 GPS coordinates (latitude/longitude)\n'
              '\u2022 Repeater IDs and signal data\n'
              '\u2022 Device antenna and power settings\n'
              '\u2022 Timestamps',
              style: TextStyle(fontSize: 13),
            ),
            SizedBox(height: 12),
            Text(
              'MeshMapper is not responsible for how third parties handle '
              'your data. Only enable this if you trust the endpoint operator.',
              style: TextStyle(fontSize: 13, color: Colors.amber),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
              appState.updatePreferences(
                appState.preferences.copyWith(
                  customApiDisclaimerAccepted: true,
                  customApiEnabled: true,
                ),
              );
            },
            child: const Text('I Understand, Enable'),
          ),
        ],
      ),
    );
  }

  void _showCustomApiUrlDialog(
      BuildContext context, AppStateProvider appState) {
    final controller = TextEditingController(
      text: appState.preferences.customApiUrl ?? '',
    );
    String? errorText;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Custom API URL'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: InputDecoration(
              labelText: 'Endpoint URL',
              hintText: 'https://api.example.com/wardrive',
              helperText: 'HTTPS required',
              errorText: errorText,
              border: const OutlineInputBorder(),
            ),
            onChanged: (_) {
              if (errorText != null) setState(() => errorText = null);
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final url = controller.text.trim();
                if (url.isEmpty) {
                  setState(() => errorText = 'URL is required');
                  return;
                }
                final uri = Uri.tryParse(url);
                if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
                  setState(() => errorText = 'Invalid URL');
                  return;
                }
                if (uri.scheme != 'https') {
                  setState(() => errorText = 'HTTPS is required');
                  return;
                }
                Navigator.pop(context);
                appState.updatePreferences(
                  appState.preferences.copyWith(customApiUrl: url),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showCustomApiKeyDialog(
      BuildContext context, AppStateProvider appState) {
    final controller = TextEditingController(
      text: appState.preferences.customApiKey ?? '',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Custom API Key'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'API Key',
            hintText: 'Enter your API key',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final key = controller.text.trim();
              if (key.isEmpty) return;
              Navigator.pop(context);
              appState.updatePreferences(
                appState.preferences.copyWith(customApiKey: key),
              );
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _importCustomApiFromClipboard(
      BuildContext context, AppStateProvider appState) async {
    final clipData = await Clipboard.getData('text/plain');
    final text = clipData?.text?.trim();

    if (text == null || text.isEmpty) {
      if (context.mounted) AppToast.error(context, 'Clipboard is empty');
      return;
    }

    // Expected format: meshmapper://custom-api?url=example.com/api.php&key=xxxxxxxxxx
    if (!text.startsWith('meshmapper://')) {
      if (context.mounted) {
        AppToast.error(context, 'No meshmapper:// link found in clipboard');
      }
      return;
    }

    try {
      final uri = Uri.parse(text);
      final rawUrl = uri.queryParameters['url'];
      final key = uri.queryParameters['key'];

      if (rawUrl == null || rawUrl.isEmpty) {
        if (context.mounted) {
          AppToast.error(context, 'Link is missing the url parameter');
        }
        return;
      }
      if (key == null || key.isEmpty) {
        if (context.mounted) {
          AppToast.error(context, 'Link is missing the key parameter');
        }
        return;
      }

      final fullUrl = 'https://$rawUrl';

      // Validate the constructed URL
      final parsed = Uri.tryParse(fullUrl);
      if (parsed == null || !parsed.hasAuthority) {
        if (context.mounted) {
          AppToast.error(context, 'Invalid URL in link: $rawUrl');
        }
        return;
      }

      appState.updatePreferences(
        appState.preferences.copyWith(
          customApiUrl: fullUrl,
          customApiKey: key,
        ),
      );

      if (context.mounted) {
        AppToast.success(context, 'Imported endpoint: $rawUrl');
      }
      debugLog('[CUSTOM API] Imported endpoint from clipboard: $fullUrl');
    } catch (e) {
      debugError('[CUSTOM API] Failed to parse clipboard link: $e');
      if (context.mounted) {
        AppToast.error(context, 'Invalid meshmapper:// link');
      }
    }
  }
}
