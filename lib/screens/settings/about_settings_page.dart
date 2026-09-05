import 'dart:io' show File;

import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:intl/intl.dart';

import '../../providers/app_state_provider.dart';
import '../../services/debug_file_logger.dart';
import '../../utils/constants.dart';
import '../../widgets/app_toast.dart';
import '../../widgets/bug_report_dialog.dart';
import '../../widgets/upload_logs_dialog.dart';
import 'settings_section_card.dart';

/// Settings folder: About & Support.
class AboutSettingsPage extends StatefulWidget {
  const AboutSettingsPage({super.key});

  @override
  State<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

class _AboutSettingsPageState extends State<AboutSettingsPage> {
  // Developer mode tap counter state
  int _versionTapCount = 0;
  DateTime? _lastVersionTap;

  Future<void> _showUploadLogsDialog(
      BuildContext context, AppStateProvider appState) async {
    final result = await showUploadLogsDialog(context, appState);

    if (!context.mounted || result == null) return;

    if (result.success) {
      String message =
          'Uploaded ${result.uploadedCount} log file${result.uploadedCount == 1 ? '' : 's'}';
      if (result.failedCount > 0) {
        message += ' (${result.failedCount} failed)';
      }
      AppToast.success(context, message);
    } else if (result.errorMessage != null) {
      AppToast.error(context, result.errorMessage!);
    }
  }

  void _onVersionTap(AppStateProvider appState) {
    // Copy version to clipboard on every tap
    Clipboard.setData(ClipboardData(text: AppConstants.appVersion));

    final now = DateTime.now();

    // Reset if last tap was more than 2 seconds ago
    if (_lastVersionTap != null &&
        now.difference(_lastVersionTap!).inSeconds > 2) {
      _versionTapCount = 0;
    }

    _lastVersionTap = now;
    _versionTapCount++;

    if (appState.developerModeEnabled) {
      AppToast.simple(context, 'Version copied to clipboard');
      return;
    }

    if (_versionTapCount >= 7) {
      appState.setDeveloperMode(true);
      AppToast.success(context, 'Developer mode enabled!');
      _versionTapCount = 0;
    } else if (_versionTapCount >= 3) {
      final remaining = 7 - _versionTapCount;
      AppToast.simple(
        context,
        '$remaining taps to enable developer mode',
        duration: const Duration(milliseconds: 800),
      );
    } else {
      AppToast.simple(context, 'Version copied to clipboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('About & Support', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          SettingsSectionCard(title: 'About', children: [
            const ListTile(
              leading: Icon(Icons.info_outline),
              title: Text(AppConstants.appName),
              subtitle: Text('Mesh network coverage mapper'),
            ),
            ListTile(
              leading: const Icon(Icons.new_releases_outlined),
              title: const Text('Version'),
              subtitle: Text(AppConstants.appVersion),
              onTap: () => _onVersionTap(appState),
            ),
            ListTile(
              leading: const Icon(Icons.feedback_outlined),
              title: const Text('Submit Feedback'),
              subtitle: const Text('Report bugs or request features'),
              onTap: () => _showBugReportDialog(context, appState),
            ),
            ListTile(
              leading: const FaIcon(FontAwesomeIcons.github),
              title: const Text('GitHub'),
              subtitle: const Text('View issues and source code'),
              onTap: () => _launchUrl(
                  'https://github.com/MeshMapper/MeshMapper_Project'),
            ),
            ListTile(
              leading: const FaIcon(FontAwesomeIcons.discord),
              title: const Text('Discord'),
              subtitle: const Text('Join our community chat'),
              onTap: () => _launchUrl('https://discord.gg/D26P6c6QmG'),
            ),
            ListTile(
              leading: const Icon(Icons.groups),
              title: const Text('Community'),
              subtitle: const Text(
                  'Built with contributions from the Greater Ottawa Mesh Radio Enthusiasts community'),
              onTap: () => _launchUrl('https://ottawamesh.ca/'),
            ),
            // Buy Me a Coffee — external donation links are fine on Android/Web
            // but violate Apple guideline 3.1.1 on iOS, so omit it on iOS.
            if (kIsWeb || defaultTargetPlatform != TargetPlatform.iOS)
              ListTile(
                leading: const Icon(Icons.coffee),
                title: const Text('Buy us a coffee'),
                subtitle: const Text('Support MeshMapper development'),
                onTap: () => _launchUrl('https://buymeacoffee.com/meshmapper'),
              ),
          ]),

          // Debug section (always visible on mobile)
          if (!kIsWeb)
            SettingsSectionCard(title: 'Debug', children: [
              SwitchListTile(
                secondary: Icon(
                  Icons.bug_report,
                  color: appState.debugLogsEnabled ? Colors.orange : null,
                ),
                title: Row(
                  children: [
                    const Text('Debug Logs'),
                    if (appState.debugLogsEnabled) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.orange,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'LOGGING',
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
                subtitle: Text(
                  appState.debugLogsEnabled
                      ? 'Writing logs to file'
                      : 'Enable to save debug logs to device',
                ),
                value: appState.debugLogsEnabled,
                onChanged: (value) async {
                  if (value) {
                    await appState.enableDebugLogs();
                  } else {
                    await appState.disableDebugLogs();
                  }
                },
              ),
              if (appState.debugLogsEnabled ||
                  appState.debugLogFiles.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Row(
                    children: [
                      Text(
                        'Log Files',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              color: Colors.grey.shade600,
                            ),
                      ),
                      const Spacer(),
                      if (appState.debugLogFiles.isNotEmpty) ...[
                        TextButton.icon(
                          icon: const Icon(Icons.cloud_upload, size: 18),
                          label: const Text('Upload'),
                          onPressed: () =>
                              _showUploadLogsDialog(context, appState),
                        ),
                        TextButton.icon(
                          icon: const Icon(Icons.delete_sweep, size: 18),
                          label: const Text('Delete All'),
                          onPressed: () =>
                              _confirmDeleteAllLogs(context, appState),
                        ),
                      ],
                    ],
                  ),
                ),
                if (appState.debugLogFiles.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      'No debug logs yet',
                      style:
                          TextStyle(color: Colors.grey.shade500, fontSize: 13),
                    ),
                  )
                else
                  ...appState.debugLogFiles.asMap().entries.map((entry) {
                    final index = entry.key;
                    final file = entry.value;
                    final filename = file.path.split('/').last;
                    final sizeBytes = file.lengthSync();
                    final isCurrentLog = index == 0;
                    final timestampMatch =
                        RegExp(r'meshmapper-debug-(\d+)\.txt')
                            .firstMatch(filename);
                    final fileDate = timestampMatch != null
                        ? DateTime.fromMillisecondsSinceEpoch(
                            int.parse(timestampMatch.group(1)!) * 1000)
                        : null;
                    final dateStr = fileDate != null
                        ? DateFormat('MMM d, h:mm a').format(fileDate)
                        : filename;

                    String sizeDisplay;
                    final partCount =
                        DebugFileLogger.estimatePartCount(sizeBytes);
                    if (sizeBytes >= DebugFileLogger.maxUploadSizeBytes) {
                      final sizeMb =
                          (sizeBytes / 1024 / 1024).toStringAsFixed(1);
                      sizeDisplay = '$sizeMb MB ($partCount parts)';
                    } else {
                      sizeDisplay =
                          '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
                    }
                    if (isCurrentLog) {
                      sizeDisplay = '$sizeDisplay (current)';
                    }

                    return ListTile(
                      leading: const Icon(Icons.description, size: 20),
                      title:
                          Text(dateStr, style: const TextStyle(fontSize: 13)),
                      subtitle: Text(
                        sizeDisplay,
                        style: const TextStyle(fontSize: 11),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.visibility, size: 20),
                            onPressed: () =>
                                _showLogViewer(context, appState, file),
                            tooltip: 'View',
                          ),
                          IconButton(
                            icon: const Icon(Icons.share, size: 20),
                            onPressed: () => appState.shareDebugLog(file),
                            tooltip: 'Share',
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ]),
        ],
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[SETTINGS] Failed to launch URL: $url - $e');
    }
  }

  Future<void> _showBugReportDialog(
      BuildContext context, AppStateProvider appState) async {
    final result = await showBugReportDialog(context, appState);

    if (!context.mounted || result == null) return;

    if (result.success) {
      // Build success message
      String message = 'Feedback submitted successfully';
      if (result.uploadedFileCount > 0) {
        message += ' with ${result.uploadedFileCount} log file(s)';
      }
      if (result.failedFileCount > 0) {
        message += ' (${result.failedFileCount} failed)';
      }

      AppToast.success(
        context,
        message,
        duration: const Duration(seconds: 5),
        actionLabel: result.issueUrl != null ? 'View' : null,
        onAction:
            result.issueUrl != null ? () => _launchUrl(result.issueUrl!) : null,
      );
    } else if (result.errorMessage != null) {
      AppToast.error(
        context,
        'Failed: ${result.errorMessage}',
        duration: const Duration(seconds: 4),
      );
    }
  }

  /// Confirm deletion of all debug logs
  void _confirmDeleteAllLogs(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete All Logs?'),
        content: Text(
          'Delete ${appState.debugLogFiles.length} debug log files?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await appState.deleteAllDebugLogs();
            },
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  /// Show debug log viewer dialog
  void _showLogViewer(
      BuildContext context, AppStateProvider appState, File file) async {
    await appState.viewDebugLog(file);

    if (!context.mounted) return;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(file.path.split('/').last),
        content: SizedBox(
          width: double.maxFinite,
          height: 400,
          child: SingleChildScrollView(
            child: SelectableText(
              appState.viewingLogContent ?? 'Loading...',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () {
              appState.closeLogViewer();
              Navigator.pop(context);
            },
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
