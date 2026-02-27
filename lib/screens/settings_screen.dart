import 'dart:convert';
import 'dart:io' show File;

import 'package:flutter/foundation.dart' show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';

// Conditional import for web file helpers
import '../utils/web_file_helpers_stub.dart'
    if (dart.library.html) '../utils/web_file_helpers.dart';

import '../models/connection_state.dart';
import '../providers/app_state_provider.dart';
import '../utils/debug_logger_io.dart';
import '../utils/distance_formatter.dart';
import '../models/user_preferences.dart';
import '../services/debug_file_logger.dart';
import '../services/debug_submit_service.dart';
import '../services/gps_simulator_service.dart';
import '../services/offline_session_service.dart';
import '../services/permission_disclosure_service.dart';
import '../utils/constants.dart';
import '../widgets/bug_report_dialog.dart';
import 'package:intl/intl.dart';
import '../widgets/app_toast.dart';

/// Settings screen for user preferences and API configuration
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Developer mode tap counter state
  int _versionTapCount = 0;
  DateTime? _lastVersionTap;

  // Debug log upload tracking
  String? _uploadingFilePath;
  final Set<String> _uploadedFiles = {};

  Future<void> _uploadSingleLogFile(AppStateProvider appState, File file) async {
    final filename = file.path.split('/').last;

    setState(() {
      _uploadingFilePath = file.path;
    });

    try {
      final service = DebugSubmitService();

      // Use persistent device info
      final publicKey = appState.devicePublicKey ??
          appState.lastConnectedPublicKey ??
          'not-connected';
      final deviceName = appState.lastConnectedDeviceName ?? 'not-connected';

      final success = await service.uploadDebugFileOnly(
        file: file,
        deviceId: deviceName,
        publicKey: publicKey,
        appVersion: AppConstants.appVersion,
        devicePlatform: DebugSubmitService.getDevicePlatform(),
        userNotes: 'Direct debug log upload from $deviceName',
      );

      service.dispose();

      if (!mounted) return;

      if (success) {
        setState(() {
          _uploadedFiles.add(file.path);
          _uploadingFilePath = null;
        });
        AppToast.success(context, 'Uploaded $filename');
      } else {
        setState(() {
          _uploadingFilePath = null;
        });
        AppToast.error(context, 'Failed to upload $filename');
      }
    } catch (e) {
      debugError('[SETTINGS] Log file upload error: $e');
      if (mounted) {
        setState(() {
          _uploadingFilePath = null;
        });
        AppToast.error(context, 'Upload error: $e');
      }
    }
  }

  /// Upload the current (active) log file by rotating it first
  Future<void> _uploadCurrentLogFile(AppStateProvider appState, File currentFile) async {
    final originalPath = currentFile.path;

    setState(() {
      _uploadingFilePath = originalPath;
    });

    try {
      // Rotate the log: closes current file, starts a new one
      // The original file is now closed and safe to upload
      await appState.prepareDebugLogsForUpload();

      if (!mounted) return;

      // The original file still exists at the same path, now closed
      final closedFile = File(originalPath);
      if (!closedFile.existsSync()) {
        throw Exception('Log file not found after rotation');
      }

      // Now upload the closed file
      await _uploadSingleLogFile(appState, closedFile);
    } catch (e) {
      debugError('[SETTINGS] Current log upload error: $e');
      if (mounted) {
        setState(() {
          _uploadingFilePath = null;
        });
        AppToast.error(context, 'Upload error: $e');
      }
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
    final prefs = appState.preferences;
    final isAutoMode = appState.autoPingEnabled;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        children: [
          // Appearance section
          _buildSectionHeader(context, 'Appearance'),
          ListTile(
            leading: Icon(
              prefs.themeMode == 'dark' ? Icons.dark_mode : Icons.light_mode,
            ),
            title: const Text('Theme'),
            subtitle: Text(prefs.themeMode == 'dark' ? 'Dark mode' : 'Light mode'),
            trailing: Switch(
              value: prefs.themeMode == 'dark',
              onChanged: (isDark) {
                appState.setThemeMode(isDark ? 'dark' : 'light');
              },
            ),
          ),
          ListTile(
            leading: Icon(
              prefs.isImperial ? Icons.square_foot : Icons.straighten,
            ),
            title: const Text('Units'),
            subtitle: Text(prefs.isImperial ? 'Imperial (mi, ft)' : 'Metric (km, m)'),
            trailing: Switch(
              value: prefs.isImperial,
              onChanged: (isImperial) {
                appState.setUnitSystem(isImperial ? 'imperial' : 'metric');
              },
            ),
          ),

          const Divider(),

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

          // Hybrid Mode Toggle
          SwitchListTile(
            secondary: const Icon(Icons.compare_arrows),
            title: Row(
              children: [
                const Text('Hybrid Mode'),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: () => _showHybridModeInfo(context),
                  child: Icon(
                    Icons.info_outline,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            subtitle: appState.enforceHybrid
                ? const Text(
                    'Set by Regional Admin — hybrid uses 50% fewer flood packets, improving mesh health.',
                    style: TextStyle(color: Colors.amber),
                  )
                : const Text('Combines Active and Passive modes'),
            value: appState.enforceHybrid ? true : prefs.hybridModeEnabled,
            onChanged: (isAutoMode || appState.enforceHybrid) ? null : (value) {
              appState.updatePreferences(prefs.copyWith(hybridModeEnabled: value));
            },
          ),

          // CARpeater Filter Setting
          SwitchListTile(
            secondary: const Icon(Icons.filter_alt),
            title: const Text('CARpeater Filter'),
            subtitle: Text(prefs.ignoreCarpeater && prefs.ignoreRepeaterId != null
                ? 'Pass-through: stripping 0x${prefs.ignoreRepeaterId}'
                : 'Tap to set CARpeater repeater ID'),
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

          // CARpeater ID - show when enabled
          if (prefs.ignoreCarpeater)
            ListTile(
              leading: const SizedBox(width: 24), // Indent
              title: const Text('CARpeater ID'),
              subtitle: Text(prefs.ignoreRepeaterId != null
                  ? '0x${prefs.ignoreRepeaterId}'
                  : 'Not set'),
              trailing: const Icon(Icons.chevron_right),
              enabled: !isAutoMode,
              onTap: isAutoMode ? null : () => _showRepeaterIdDialog(context, appState),
            ),

          // Anonymous Mode Toggle
          SwitchListTile(
            secondary: const Icon(Icons.visibility_off),
            title: const Text('Anonymous Mode'),
            subtitle: Text(prefs.anonymousMode
                ? 'Device broadcasts as "Anonymous"'
                : 'Device uses its real name'),
            value: prefs.anonymousMode,
            onChanged: isAutoMode ? null : (value) {
              if (value) {
                _showEnableAnonymousConfirmation(context, appState);
              } else {
                if (appState.connectionStatus == ConnectionStatus.connected) {
                  _showDisableAnonymousConfirmation(context, appState);
                } else {
                  appState.setAnonymousMode(false);
                }
              }
            },
          ),

          // Disable RSSI Filter Toggle
          SwitchListTile(
            secondary: const Icon(Icons.shield_outlined),
            title: const Text('Disable RSSI Filter'),
            subtitle: Text(prefs.disableRssiFilter
                ? 'Allows all signal strengths'
                : 'Drops signals stronger than -30 dBm'),
            value: prefs.disableRssiFilter,
            onChanged: isAutoMode ? null : (value) {
              if (value) {
                _showDisableRssiFilterConfirmation(context, appState);
              } else {
                appState.updatePreferences(prefs.copyWith(disableRssiFilter: false));
              }
            },
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

          // Background Mode - for "Always" location permission (iOS and Android)
          if (!kIsWeb) ...[
            const Divider(),
            _buildSectionHeader(context, 'Background Mode'),
            _BackgroundModeToggle(appState: appState),
          ],

          const Divider(),

          // Data Management section
          _buildSectionHeader(context, 'Data Management'),
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

          // Clear Map Markers
          ListTile(
            leading: const Icon(Icons.delete_sweep),
            title: const Text('Clear Map Markers'),
            subtitle: const Text('Remove all TX/RX markers from map'),
            onTap: () => _confirmClearPings(context, appState),
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
          const ListTile(
            leading: Icon(Icons.info_outline),
            title: Text(AppConstants.appName),
          ),
          GestureDetector(
            onTap: () => _onVersionTap(appState),
            child: ListTile(
              leading: const Icon(Icons.new_releases_outlined),
              title: const Text('Version'),
              subtitle: Text(AppConstants.appVersion),
            ),
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
            onTap: () => _launchUrl('https://github.com/MeshMapper/MeshMapper_Project'),
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
            subtitle: const Text('Built with contributions from the Greater Ottawa Mesh Radio Enthusiasts community'),
            onTap: () => _launchUrl('https://ottawamesh.ca/'),
          ),
          ListTile(
            leading: const Icon(Icons.coffee),
            title: const Text('Buy us a coffee ☕'),
            subtitle: const Text('Support MeshMapper development'),
            onTap: () => _launchUrl('https://buymeacoffee.com/meshmapper'),
          ),

          // Exit Options (Android only)
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) ...[
            const Divider(),
            _buildSectionHeader(context, 'Exit Options'),

            // Auto-close toggle
            SwitchListTile(
              secondary: const Icon(Icons.exit_to_app),
              title: const Text('Close App After Disconnect'),
              subtitle: const Text('Automatically exit the app when disconnecting'),
              value: prefs.closeAppAfterDisconnect,
              onChanged: (value) => appState.setCloseAppAfterDisconnect(value),
            ),

            // Manual close button
            ListTile(
              leading: const Icon(Icons.power_settings_new, color: Colors.red),
              title: const Text('Close App'),
              subtitle: const Text('Exit the app completely'),
              onTap: () => _showCloseAppConfirmation(context, appState),
            ),
          ],

          // Developer Tools section - only visible when developer mode is enabled
          if (appState.developerModeEnabled) ...[
            const Divider(),

            _buildSectionHeader(context, 'Developer Tools'),

            // Developer mode toggle (to disable)
            SwitchListTile(
              secondary: const Icon(Icons.developer_mode),
              title: const Text('Developer Mode'),
              subtitle: const Text('Disable to hide developer tools'),
              value: appState.developerModeEnabled,
              onChanged: (value) {
                appState.setDeveloperMode(value);
              },
            ),

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
                label: formatSpeed(appState.gpsSimulatorSpeed, isImperial: prefs.isImperial),
                onChanged: (value) {
                  appState.setGpsSimulatorSpeed(value);
                },
              ),
              trailing: Text(
                formatSpeed(appState.gpsSimulatorSpeed, isImperial: prefs.isImperial),
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
                        AppToast.info(context, 'Route cleared');
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
                  AppToast.info(
                    context,
                    appState.hasSimulatorRoute
                        ? 'Reset to route start'
                        : 'GPS simulator reset to Ottawa downtown',
                  );
                },
              ),
            ),
          ],
          ], // Close developerModeEnabled conditional

          // Debug section (always visible on mobile)
          if (!kIsWeb) ...[
            const Divider(),

            _buildSectionHeader(context, 'Debug'),

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
                ...appState.debugLogFiles.asMap().entries.map((entry) {
                  final index = entry.key;
                  final file = entry.value;
                  final filename = file.path.split('/').last;
                  final sizeBytes = file.lengthSync();
                  final isUploading = _uploadingFilePath == file.path;
                  final wasUploaded = _uploadedFiles.contains(file.path);
                  // First file (index 0) is the most recent/active log - can't upload
                  final isCurrentLog = index == 0;
                  // Parse unix timestamp from filename (meshmapper-debug-{timestamp}.txt)
                  final timestampMatch = RegExp(r'meshmapper-debug-(\d+)\.txt').firstMatch(filename);
                  final fileDate = timestampMatch != null
                      ? DateTime.fromMillisecondsSinceEpoch(int.parse(timestampMatch.group(1)!) * 1000)
                      : null;
                  final dateStr = fileDate != null ? DateFormat('MMM d, h:mm a').format(fileDate) : filename;

                  // Format size and show part count for oversized files
                  String sizeDisplay;
                  final partCount = DebugFileLogger.estimatePartCount(sizeBytes);
                  if (sizeBytes >= DebugFileLogger.maxUploadSizeBytes) {
                    final sizeMb = (sizeBytes / 1024 / 1024).toStringAsFixed(1);
                    sizeDisplay = '$sizeMb MB ($partCount parts)';
                  } else {
                    sizeDisplay = '${(sizeBytes / 1024).toStringAsFixed(1)} KB';
                  }
                  if (isCurrentLog) {
                    sizeDisplay = '$sizeDisplay (current)';
                  }

                  return ListTile(
                    leading: const Icon(Icons.description, size: 20),
                    title: Text(dateStr, style: const TextStyle(fontSize: 13)),
                    subtitle: Text(
                      sizeDisplay,
                      style: const TextStyle(fontSize: 11),
                    ),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Upload button
                        if (wasUploaded)
                          Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            child: const Icon(
                              Icons.check_circle,
                              size: 20,
                              color: Colors.green,
                            ),
                          )
                        else if (isUploading)
                          Container(
                            width: 40,
                            height: 40,
                            alignment: Alignment.center,
                            child: const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          )
                        else
                          IconButton(
                            icon: const Icon(Icons.cloud_upload, size: 20),
                            onPressed: _uploadingFilePath != null
                                ? null
                                : () => isCurrentLog
                                    ? _uploadCurrentLogFile(appState, file)
                                    : _uploadSingleLogFile(appState, file),
                            tooltip: isCurrentLog
                                ? 'Close log and upload'
                                : 'Upload to developer',
                          ),
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
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[SETTINGS] Failed to launch URL: $url - $e');
    }
  }

  Future<void> _showBugReportDialog(BuildContext context, AppStateProvider appState) async {
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
        onAction: result.issueUrl != null ? () => _launchUrl(result.issueUrl!) : null,
      );
    } else if (result.errorMessage != null) {
      AppToast.error(
        context,
        'Failed: ${result.errorMessage}',
        duration: const Duration(seconds: 4),
      );
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

  void _showDisableRssiFilterConfirmation(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disable RSSI Filter?'),
        content: const Text(
          'By disabling this filter, you are confirming that you are not operating '
          'a carpeater (a repeater co-located with your device).\n\n'
          'If this filter is disabled while a carpeater is present, your device will '
          'report false coverage data to the MeshMapper community map. This degrades '
          'map accuracy for everyone.\n\n'
          'Only disable this if you are certain no co-located repeater is within range.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              appState.updatePreferences(
                appState.preferences.copyWith(disableRssiFilter: true),
              );
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Disable Filter'),
          ),
        ],
      ),
    );
  }

  void _showEnableAnonymousConfirmation(BuildContext context, AppStateProvider appState) {
    final isConnected = appState.connectionStatus == ConnectionStatus.connected;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable Anonymous Mode?'),
        content: Text(
          'Your device will be renamed to "Anonymous" for all mesh pings. '
          'Other mesh users will not see your companion name.\n\n'
          'Your public key is still used to authenticate your session, but '
          'neither your sessions nor your pings are linked to it on the server.\n\n'
          '${isConnected ? 'Your device will disconnect and reconnect automatically.\n\n' : ''}'
          'If the app crashes or BLE disconnects unexpectedly, your device '
          'may remain named "Anonymous" until you reconnect and properly disconnect. '
          'Always use the Disconnect button to restore your device name.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              appState.setAnonymousMode(true);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  void _showDisableAnonymousConfirmation(BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disable Anonymous Mode?'),
        content: const Text(
          'This will disconnect and reconnect your device to restore your companion name. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              appState.setAnonymousMode(false);
            },
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  void _showHybridModeInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.compare_arrows, size: 24),
            SizedBox(width: 8),
            Text('Hybrid Mode'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Replaces Active Mode. Alternates between auto-pinging #wardriving and sending zero-hop discovery pings each interval, tracking repeaters from pings, nearby repeaters, and received mesh traffic.',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 12),
            Text('How it works:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 4),
            Text(
              'Discovery \u2192 wait \u2192 TX Ping \u2192 wait \u2192 Discovery \u2192 ...',
              style: TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            SizedBox(height: 12),
            Text('Interval timing:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 4),
            Text(
              'At 15s interval, each ping type fires every 30s. Discovery\'s 30s firmware rate limit is naturally respected.',
              style: TextStyle(fontSize: 13),
            ),
            SizedBox(height: 12),
            Text('When enabled:', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 4),
            Text(
              '\u2022 Replaces the Active button with Hybrid\n'
              '\u2022 50% less TX airtime vs Active Mode\n'
              '\u2022 Discovery finds nearby repeaters\n'
              '\u2022 TX pings test coverage through them',
              style: TextStyle(fontSize: 13),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Got it'),
          ),
        ],
      ),
    );
  }

  void _showIntervalSelector(BuildContext context, AppStateProvider appState) {
    final minInterval = appState.minModeInterval;
    var currentInterval = appState.preferences.autoPingInterval;

    // Auto-bump if current interval is below the admin minimum
    if (currentInterval < minInterval) {
      currentInterval = minInterval;
      appState.updatePreferences(
        appState.preferences.copyWith(autoPingInterval: minInterval),
      );
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Auto-Ping Interval'),
        content: RadioGroup<int>(
          groupValue: currentInterval,
          onChanged: (value) {
            if (value != null) {
              appState.updatePreferences(
                appState.preferences.copyWith(autoPingInterval: value),
              );
              Navigator.pop(context);
            }
          },
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: AutoPingInterval.values.map((interval) {
              final isDisabled = interval < minInterval;

              String description;
              if (interval == 15) {
                description = 'Fast (More coverage, causes more mesh load)';
              } else if (interval == 30) {
                description = 'Normal (Balanced coverage and mesh load)';
              } else {
                description = 'Slow (Less coverage, little mesh load)';
              }

              final tile = RadioListTile<int>(
                title: Text('$interval seconds'),
                subtitle: isDisabled
                    ? const Text(
                        'Set by Regional Admin — slower intervals reduce congestion in your region',
                        style: TextStyle(color: Colors.amber),
                      )
                    : Text(description),
                value: interval,
              );

              if (isDisabled) {
                return IgnorePointer(
                  child: Opacity(
                    opacity: 0.5,
                    child: tile,
                  ),
                );
              }
              return tile;
            }).toList(),
          ),
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
        title: const Text('CARpeater Repeater ID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Enter the repeater ID of your CARpeater (2 hex digits):'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'CARpeater ID',
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
              'Multi-hop packets through your CARpeater will be stripped to report the underlying repeater with null signal data. Single-hop CARpeater packets are still dropped.',
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
                AppToast.warning(context, 'Invalid hex value. Use 2 digits (00-FF).');
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
      debugLog('[SETTINGS] Opening file picker...');

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
          debugLog('[SETTINGS] File picked: ${result.files.first.name}');
          final file = result.files.first;
          final content = file.bytes != null
              ? String.fromCharCodes(file.bytes!)
              : null;

          if (content != null && context.mounted) {
            debugLog('[SETTINGS] File content loaded, ${content.length} chars');
            _processRouteFile(context, appState, content, file.name);
          }
        }
      }
    } catch (e, stackTrace) {
      debugLog('[SETTINGS] Error: $e');
      debugLog('[SETTINGS] Stack trace: $stackTrace');
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
        debugLog('[SETTINGS] File picked: $filename');
        debugLog('[SETTINGS] File content loaded, ${content.length} chars');
        _processRouteFile(context, appState, content, filename);
      },
    );
  }

  void _processRouteFile(BuildContext context, AppStateProvider appState, String content, String filename) {
    debugLog('[SETTINGS] Calling loadSimulatorRoute...');
    final success = appState.loadSimulatorRoute(
      content,
      filename: filename,
    );
    debugLog('[SETTINGS] loadSimulatorRoute returned: $success');

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
    // Show loading indicator
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Row(
          children: [
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
            ),
            SizedBox(width: 12),
            Text('Uploading session...'),
          ],
        ),
        duration: Duration(seconds: 30), // Will be dismissed when upload completes
      ),
    );

    final result = await appState.uploadOfflineSessionWithAuth(filename);

    if (context.mounted) {
      // Dismiss loading indicator
      ScaffoldMessenger.of(context).hideCurrentSnackBar();

      // Show result
      String message;
      Color backgroundColor;

      switch (result) {
        case OfflineUploadResult.success:
          message = 'Uploaded: $filename';
          backgroundColor = Colors.green;
          break;
        case OfflineUploadResult.notFound:
          message = 'Session not found: $filename';
          backgroundColor = Colors.red;
          break;
        case OfflineUploadResult.invalidSession:
          message = 'Invalid session data or missing device credentials';
          backgroundColor = Colors.red;
          break;
        case OfflineUploadResult.authFailed:
          message = 'Authentication failed - Advert your device on the mesh';
          backgroundColor = Colors.red;
          break;
        case OfflineUploadResult.partialFailure:
          message = 'Partial upload - some pings failed';
          backgroundColor = Colors.orange;
          break;
      }

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          duration: const Duration(seconds: 3),
          backgroundColor: backgroundColor,
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

  void _showCloseAppConfirmation(BuildContext context, AppStateProvider appState) {
    final isConnected = appState.isConnected;

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Close App'),
        content: Text(
          isConnected
              ? 'This will disconnect from the device and close the app. Continue?'
              : 'This will close the app. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              appState.exitApp();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Close App'),
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
    // Show prominent disclosure before requesting background location
    final accepted = await PermissionDisclosureService.showBackgroundLocationDisclosure(context);
    if (!accepted) {
      return; // User declined
    }

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

  void _showDisableDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Disable Background Location'),
        content: const Text(
          'Background location can only be disabled through your device\'s Settings app.\n\n'
          'Go to Settings > Location and change permission to "While Using" or "Never".',
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
                _showDisableDialog();
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
    final isUploaded = session.uploaded;

    return ListTile(
      leading: Icon(
        isUploaded ? Icons.cloud_done : Icons.cloud_off,
        color: isUploaded ? Colors.green : Colors.orange,
      ),
      title: Text(session.filename),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${session.pingCount} pings • ${session.displayDate}'),
          if (isUploaded)
            const Text(
              'Uploaded',
              style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.w500),
            ),
          if (session.deviceName != null)
            Text(
              'Device: ${session.deviceName}',
              style: TextStyle(color: Colors.grey.shade600, fontSize: 11),
            ),
        ],
      ),
      isThreeLine: session.deviceName != null || isUploaded,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Download button - always available
          IconButton(
            icon: const Icon(Icons.download),
            onPressed: onDownload,
            tooltip: 'Download JSON',
            color: Colors.blue,
          ),
          // Upload button - only when not uploaded
          if (!isUploaded)
            IconButton(
              icon: const Icon(Icons.cloud_upload),
              onPressed: onUpload,
              tooltip: 'Upload session',
              color: Colors.green,
            ),
          // Delete button - always available
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
