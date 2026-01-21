import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';

// Conditional import for web file helpers
import '../utils/web_file_helpers_stub.dart'
    if (dart.library.html) '../utils/web_file_helpers.dart';

import '../providers/app_state_provider.dart';
import '../models/user_preferences.dart';
import '../services/gps_simulator_service.dart';
import '../services/offline_session_service.dart';
import '../utils/constants.dart';

/// Settings screen for user preferences and API configuration
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final prefs = appState.preferences;
    final isAutoMode = appState.autoPingEnabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        children: [
          // Wardriving Settings section
          _buildSectionHeader(context, 'Wardriving Settings'),

          // Auto-Ping Interval Selector
          ListTile(
            leading: const Icon(Icons.timer),
            title: const Text('Auto-Ping Interval'),
            subtitle: Text(prefs.autoPingIntervalDisplay),
            trailing: const Icon(Icons.chevron_right),
            enabled: !isAutoMode,
            onTap: isAutoMode ? null : () => _showIntervalSelector(context, appState),
          ),

          // Carpeater Ignore Setting
          SwitchListTile(
            secondary: const Icon(Icons.filter_alt),
            title: const Text('Ignore Carpeater'),
            subtitle: Text(prefs.ignoreCarpeater && prefs.ignoreRepeaterId != null
                ? 'Filtering repeater 0x${prefs.ignoreRepeaterId}'
                : 'Tap to set repeater ID to ignore'),
            value: prefs.ignoreCarpeater,
            onChanged: isAutoMode ? null : (value) {
              if (value && prefs.ignoreRepeaterId == null) {
                // Show dialog to set repeater ID when enabling
                _showRepeaterIdDialog(context, appState);
              } else {
                appState.updatePreferences(prefs.copyWith(ignoreCarpeater: value));
              }
            },
          ),

          // Repeater ID to Ignore - show when enabled
          if (prefs.ignoreCarpeater)
            ListTile(
              leading: const SizedBox(width: 24), // Indent
              title: const Text('Repeater ID'),
              subtitle: Text(prefs.ignoreRepeaterId != null
                  ? '0x${prefs.ignoreRepeaterId}'
                  : 'Not set'),
              trailing: const Icon(Icons.chevron_right),
              enabled: !isAutoMode,
              onTap: isAutoMode ? null : () => _showRepeaterIdDialog(context, appState),
            ),

          // Lock indicator
          if (isAutoMode)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.lock, size: 16, color: Colors.orange.shade700),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Settings locked during auto-ping mode',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.orange.shade700,
                        fontStyle: FontStyle.italic,
                      ),
                    ),
                  ),
                ],
              ),
            ),

          // Background Mode (iOS only - for "Always" location permission)
          if (!kIsWeb && Platform.isIOS) ...[
            const Divider(),
            _buildSectionHeader(context, 'Background Mode'),
            _BackgroundModeToggle(appState: appState),
          ],

          const Divider(),

          // Queue section
          _buildSectionHeader(context, 'API Queue'),
          ListTile(
            leading: const Icon(Icons.cloud_queue),
            title: const Text('Queued Pings'),
            subtitle: Text('${appState.queueSize} items waiting'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.cloud_upload),
                  onPressed: appState.queueSize > 0
                      ? () => appState.forceUploadQueue()
                      : null,
                  tooltip: 'Force upload',
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: appState.queueSize > 0
                      ? () => _confirmClearQueue(context, appState)
                      : null,
                  tooltip: 'Clear queue',
                ),
              ],
            ),
          ),

          // Offline Sessions
          if (appState.offlineSessions.isNotEmpty) ...[
            _buildSectionHeader(context, 'Offline Sessions'),
            ...appState.offlineSessions.map((session) => _OfflineSessionTile(
              session: session,
              onUpload: () => _uploadOfflineSession(context, appState, session.filename),
              onDelete: () => _confirmDeleteOfflineSession(context, appState, session.filename),
              onDownload: () => _downloadOfflineSession(context, appState, session.filename),
            )),
          ],

          const Divider(),
          
          // Statistics section
          _buildSectionHeader(context, 'Statistics'),
          ListTile(
            leading: const Icon(Icons.send),
            title: const Text('TX Pings'),
            trailing: Text(
              '${appState.pingStats.txCount}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.call_received),
            title: const Text('RX Pings'),
            trailing: Text(
              '${appState.pingStats.rxCount}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.check_circle),
            title: const Text('Successful Uploads'),
            trailing: Text(
              '${appState.pingStats.successfulUploads}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          ListTile(
            leading: const Icon(Icons.delete_forever),
            title: const Text('Clear Map Markers'),
            onTap: () => _confirmClearPings(context, appState),
          ),

          const Divider(),

          // Device Info section
          _buildSectionHeader(context, 'Device'),
          ListTile(
            leading: const Icon(Icons.perm_identity),
            title: const Text('Device ID'),
            subtitle: Text(appState.deviceId),
          ),

          const Divider(),

          // About section
          _buildSectionHeader(context, 'About'),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: Text(AppConstants.appName),
          ),
          ListTile(
            leading: const Icon(Icons.new_releases_outlined),
            title: const Text('Version'),
            subtitle: Text(AppConstants.appVersion),
          ),
          ListTile(
            leading: const Icon(Icons.bug_report),
            title: const Text('Issues & Feedback'),
            subtitle: const Text('Report bugs or request features'),
            onTap: () => _launchUrl('https://github.com/MeshMapper/MeshMapper_Project'),
          ),

          const Divider(),

          // Debug / Testing section
          _buildSectionHeader(context, 'Debug / Testing'),

          // GPS Simulator Toggle
          SwitchListTile(
            secondary: Icon(
              Icons.gps_fixed,
              color: appState.isGpsSimulatorEnabled ? Colors.orange : null,
            ),
            title: Row(
              children: [
                const Text('GPS Simulator'),
                if (appState.isGpsSimulatorEnabled) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.orange,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'SIMULATED',
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
            subtitle: Text(appState.isGpsSimulatorEnabled
                ? 'Smooth simulated movement active'
                : 'Use simulated GPS for testing'),
            value: appState.isGpsSimulatorEnabled,
            onChanged: (value) {
              if (value) {
                appState.enableGpsSimulator();
              } else {
                appState.disableGpsSimulator();
              }
            },
          ),

          // Simulator Settings (only when enabled)
          if (appState.isGpsSimulatorEnabled) ...[
            // Speed Slider
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Simulation Speed'),
              subtitle: Slider(
                value: appState.gpsSimulatorSpeed,
                min: 10,
                max: 120,
                divisions: 11,
                label: '${appState.gpsSimulatorSpeed.round()} km/h',
                onChanged: (value) {
                  appState.setGpsSimulatorSpeed(value);
                },
              ),
              trailing: Text(
                '${appState.gpsSimulatorSpeed.round()} km/h',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),

            // Pattern Selector
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Movement Pattern'),
              trailing: SizedBox(
                width: 180,
                child: DropdownButton<SimulatorPattern>(
                  value: appState.gpsSimulatorPattern,
                  underline: const SizedBox(),
                  isExpanded: true,
                  items: [
                    const DropdownMenuItem(
                      value: SimulatorPattern.straight,
                      child: Text('Straight Line', overflow: TextOverflow.ellipsis),
                    ),
                    const DropdownMenuItem(
                      value: SimulatorPattern.circle,
                      child: Text('Circle', overflow: TextOverflow.ellipsis),
                    ),
                    const DropdownMenuItem(
                      value: SimulatorPattern.randomWalk,
                      child: Text('Random Walk', overflow: TextOverflow.ellipsis),
                    ),
                    if (appState.hasSimulatorRoute)
                      DropdownMenuItem(
                        value: SimulatorPattern.route,
                        child: Text(
                          'Route: ${appState.simulatorRouteName ?? "Loaded"}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: (pattern) {
                    if (pattern != null) {
                      appState.setGpsSimulatorPattern(pattern);
                    }
                  },
                ),
              ),
            ),

            // Load Route File
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Load Route File'),
              subtitle: Text(appState.hasSimulatorRoute
                  ? '${appState.simulatorRouteName} (${appState.simulatorRoutePointCount} points)'
                  : 'KML or GPX file'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.folder_open),
                    onPressed: () => _pickRouteFile(context, appState),
                    tooltip: 'Load route file',
                  ),
                  if (appState.hasSimulatorRoute)
                    IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        appState.clearSimulatorRoute();
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Route cleared'),
                            duration: Duration(seconds: 2),
                          ),
                        );
                      },
                      tooltip: 'Clear route',
                    ),
                ],
              ),
            ),

            // Reset Position Button
            ListTile(
              leading: const SizedBox(width: 24),
              title: const Text('Reset Position'),
              subtitle: Text(appState.hasSimulatorRoute
                  ? 'Reset to route start'
                  : 'Reset to Ottawa downtown'),
              trailing: IconButton(
                icon: const Icon(Icons.restart_alt),
                onPressed: () {
                  appState.resetGpsSimulator();
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(appState.hasSimulatorRoute
                          ? 'Reset to route start'
                          : 'GPS simulator reset to Ottawa downtown'),
                      duration: const Duration(seconds: 2),
                    ),
                  );
                },
              ),
            ),
          ],

          // Debug Logs Toggle (mobile only)
          if (!kIsWeb) ...[
            const Divider(height: 32, thickness: 1),

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
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
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

            // Log Files List (show when toggle is ON or when files exist)
            if (appState.debugLogsEnabled || appState.debugLogFiles.isNotEmpty) ...[
              // Section header with Delete All button
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Text(
                      'Debug Log Files',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            color: Colors.grey.shade600,
                          ),
                    ),
                    const Spacer(),
                    if (appState.debugLogFiles.isNotEmpty)
                      TextButton.icon(
                        icon: const Icon(Icons.delete_sweep, size: 18),
                        label: const Text('Delete All'),
                        onPressed: () => _confirmDeleteAllLogs(context, appState),
                      ),
                  ],
                ),
              ),

              // Log files list or empty message
              if (appState.debugLogFiles.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    'No debug logs yet',
                    style: TextStyle(color: Colors.grey.shade500, fontSize: 13),
                  ),
                )
              else
                ...appState.debugLogFiles.map((file) {
                  final filename = file.path.split('/').last;
                  final sizeKb = (file.lengthSync() / 1024).toStringAsFixed(1);

                  return ListTile(
                    leading: const Icon(Icons.description, size: 20),
                    title: Text(filename, style: const TextStyle(fontSize: 13)),
                    subtitle: Text('$sizeKb KB', style: const TextStyle(fontSize: 11)),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // View button
                        IconButton(
                          icon: const Icon(Icons.visibility, size: 20),
                          onPressed: () => _showLogViewer(context, appState, file),
                          tooltip: 'View',
                        ),
                        // Share button
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
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.bold,
            ),
      ),
    );
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  void _confirmClearQueue(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Queue?'),
        content: Text(
          'This will permanently delete ${appState.queueSize} queued pings that haven\'t been uploaded yet.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearQueue();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _confirmClearPings(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear Map Markers?'),
        content: const Text(
          'This will remove all TX/RX markers from the map. This won\'t affect uploaded data.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.clearPings();
              Navigator.pop(context);
            },
            child: const Text('Clear'),
          ),
        ],
      ),
    );
  }

  void _showIntervalSelector(BuildContext context, AppStateProvider appState) {
    final currentInterval = appState.preferences.autoPingInterval;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Auto-Ping Interval'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: AutoPingInterval.values.map((interval) {
            final isSelected = interval == currentInterval;

            return RadioListTile<int>(
              title: Text('$interval seconds'),
              subtitle: Text(interval == 15
                  ? 'Fast (More coverage, causes more mesh load)'
                  : interval == 30
                      ? 'Normal (Balanced coverage and mesh load)'
                      : 'Slow (Less coverage, little mesh load)'),
              value: interval,
              groupValue: currentInterval,
              selected: isSelected,
              onChanged: (value) {
                if (value != null) {
                  appState.updatePreferences(
                    appState.preferences.copyWith(autoPingInterval: value),
                  );
                  Navigator.pop(context);
                }
              },
            );
          }).toList(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }

  void _showRepeaterIdDialog(BuildContext context, AppStateProvider appState) {
    final controller = TextEditingController(
      text: appState.preferences.ignoreRepeaterId ?? '',
    );

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ignore Repeater ID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter the repeater ID to ignore (2 hex digits):'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Repeater ID',
                hintText: 'FF',
                prefixText: '0x',
                border: OutlineInputBorder(),
              ),
              maxLength: 2,
              textCapitalization: TextCapitalization.characters,
              onChanged: (value) {
                // Keep only valid hex characters
                final filtered = value.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
                if (filtered != value) {
                  controller.value = controller.value.copyWith(
                    text: filtered,
                    selection: TextSelection.collapsed(offset: filtered.length),
                  );
                }
              },
            ),
            const SizedBox(height: 8),
            Text(
              'Enter 2-character hex ID (e.g., FF) to ignore a specific repeater.\nLeave empty to disable.',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final value = controller.text.trim().toUpperCase();
              final isValidHex = value.isEmpty ||
                  (value.length == 2 && RegExp(r'^[0-9A-F]{2}$').hasMatch(value));

              if (isValidHex) {
                // Enable ignoreCarpeater when setting a repeater ID
                // Store in uppercase for consistency
                appState.updatePreferences(
                  appState.preferences.copyWith(
                    ignoreRepeaterId: value.isEmpty ? null : value,
                    ignoreCarpeater: value.isNotEmpty, // Enable if ID is set
                  ),
                );
                Navigator.pop(context);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Invalid hex value. Use 2 digits (00-FF).'),
                  ),
                );
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _pickRouteFile(BuildContext context, AppStateProvider appState) async {
    try {
      print('[SETTINGS] Opening file picker...');

      if (kIsWeb) {
        // Use dart:html directly on web to avoid file_picker initialization issues
        _pickRouteFileWeb(context, appState);
      } else {
        // Use file_picker on mobile
        final result = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: ['kml', 'gpx', 'xml'],
          withData: true,
        );

        if (result != null && result.files.isNotEmpty) {
          print('[SETTINGS] File picked: ${result.files.first.name}');
          final file = result.files.first;
          final content = file.bytes != null
              ? String.fromCharCodes(file.bytes!)
              : null;

          if (content != null) {
            print('[SETTINGS] File content loaded, ${content.length} chars');
            _processRouteFile(context, appState, content, file.name);
          }
        }
      }
    } catch (e, stackTrace) {
      print('[SETTINGS] Error: $e');
      print('[SETTINGS] Stack trace: $stackTrace');
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading file: ${e.toString()}'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  void _pickRouteFileWeb(BuildContext context, AppStateProvider appState) {
    pickFileWeb(
      accept: '.kml,.gpx,.xml',
      onFilePicked: (content, filename) {
        print('[SETTINGS] File picked: $filename');
        print('[SETTINGS] File content loaded, ${content.length} chars');
        _processRouteFile(context, appState, content, filename);
      },
    );
  }

  void _processRouteFile(BuildContext context, AppStateProvider appState, String content, String filename) {
    print('[SETTINGS] Calling loadSimulatorRoute...');
    final success = appState.loadSimulatorRoute(
      content,
      filename: filename,
    );
    print('[SETTINGS] loadSimulatorRoute returned: $success');

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Loaded route: ${appState.simulatorRouteName} (${appState.simulatorRoutePointCount} points)'
              : 'Failed to load route file'),
          duration: const Duration(seconds: 3),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  Future<void> _uploadOfflineSession(BuildContext context, AppStateProvider appState, String filename) async {
    final success = await appState.uploadOfflineSession(filename);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(success
              ? 'Uploaded and deleted: $filename'
              : 'Failed to upload: $filename'),
          duration: const Duration(seconds: 3),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  void _confirmDeleteOfflineSession(BuildContext context, AppStateProvider appState, String filename) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Offline Session?'),
        content: Text(
          'This will permanently delete the offline session "$filename" without uploading.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.deleteOfflineSession(filename);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _downloadOfflineSession(BuildContext context, AppStateProvider appState, String filename) {
    try {
      final sessionData = appState.offlineSessionService.getSessionData(filename);
      if (sessionData == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to load session data'),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }

      // Convert to pretty JSON
      final jsonString = const JsonEncoder.withIndent('  ').convert(sessionData);

      if (kIsWeb && isWebFileHelpersAvailable) {
        // Web: Create a blob and trigger download
        downloadFileWeb(
          content: jsonString,
          filename: filename,
          mimeType: 'application/json',
        );

        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Downloaded: $filename'),
              duration: const Duration(seconds: 2),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        // Mobile: Not yet implemented
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Mobile download coming soon - use web version'),
            duration: Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error downloading: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
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
  void _showLogViewer(BuildContext context, AppStateProvider appState, File file) async {
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

/// Widget for Background Mode toggle (iOS "Always" location permission)
class _BackgroundModeToggle extends StatefulWidget {
  final AppStateProvider appState;

  const _BackgroundModeToggle({required this.appState});

  @override
  State<_BackgroundModeToggle> createState() => _BackgroundModeToggleState();
}

class _BackgroundModeToggleState extends State<_BackgroundModeToggle>
    with WidgetsBindingObserver {
  bool _hasAlwaysPermission = false;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Re-check permission when app comes back to foreground
    // (user may have changed it in Settings)
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final hasPermission = await widget.appState.hasAlwaysLocationPermission();
    if (mounted) {
      setState(() {
        _hasAlwaysPermission = hasPermission;
        _isLoading = false;
      });
    }
  }

  Future<void> _requestPermission() async {
    setState(() => _isLoading = true);

    final granted = await widget.appState.requestAlwaysLocationPermission();

    if (mounted) {
      setState(() {
        _hasAlwaysPermission = granted;
        _isLoading = false;
      });

      if (!granted) {
        // Show dialog suggesting to open Settings
        _showPermissionDeniedDialog();
      }
    }
  }

  void _showPermissionDeniedDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Permission Required'),
        content: const Text(
          'To enable background location tracking, please go to Settings and set Location to "Always".\n\n'
          'This allows the app to track your location while in the background for continuous wardriving.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openAppSettings();
            },
            child: const Text('Open Settings'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      secondary: Icon(
        Icons.location_on,
        color: _hasAlwaysPermission ? Colors.green : null,
      ),
      title: Row(
        children: [
          const Text('Background Location'),
          if (_hasAlwaysPermission) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.green,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'ALWAYS',
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
        _hasAlwaysPermission
            ? 'Location tracking works in background'
            : 'Enable for background wardriving',
      ),
      value: _hasAlwaysPermission,
      onChanged: _isLoading
          ? null
          : (value) {
              if (value) {
                _requestPermission();
              } else {
                // Can't revoke - direct to settings
                _showPermissionDeniedDialog();
              }
            },
    );
  }
}

/// Widget for displaying an offline session in the list
class _OfflineSessionTile extends StatelessWidget {
  final OfflineSession session;
  final VoidCallback onUpload;
  final VoidCallback onDelete;
  final VoidCallback onDownload;

  const _OfflineSessionTile({
    required this.session,
    required this.onUpload,
    required this.onDelete,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.cloud_off, color: Colors.orange),
      title: Text(session.filename),
      subtitle: Text('${session.pingCount} pings • ${session.displayDate}'),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: onDownload,
            tooltip: 'Download JSON',
            color: Colors.blue,
          ),
          IconButton(
            icon: const Icon(Icons.cloud_upload),
            onPressed: onUpload,
            tooltip: 'Upload session',
            color: Colors.green,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: onDelete,
            tooltip: 'Delete session',
            color: Colors.red,
          ),
        ],
      ),
    );
  }
}
