import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';

// Conditional import for web file helpers
import '../../utils/web_file_helpers_stub.dart'
    if (dart.library.html) '../../utils/web_file_helpers.dart';

import '../../providers/app_state_provider.dart';
import '../../services/gps_simulator_service.dart';
import '../../utils/debug_logger_io.dart';
import '../../utils/distance_formatter.dart';
import '../../widgets/app_toast.dart';
import 'settings_section_card.dart';

/// Settings folder: Developer Tools.
class DeveloperSettingsPage extends StatelessWidget {
  const DeveloperSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final prefs = appState.preferences;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Developer Tools', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          SettingsSectionCard(children: [
            SwitchListTile(
              secondary: const Icon(Icons.developer_mode),
              title: const Text('Developer Mode'),
              subtitle: const Text('Disable to hide developer tools'),
              value: appState.developerModeEnabled,
              onChanged: (value) {
                appState.setDeveloperMode(value);
              },
            ),
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
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
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
            if (appState.isGpsSimulatorEnabled) ...[
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('Simulation Speed'),
                subtitle: Slider(
                  value: appState.gpsSimulatorSpeed,
                  min: 10,
                  max: 300,
                  divisions: 29,
                  label: formatSpeed(appState.gpsSimulatorSpeed,
                      isImperial: prefs.isImperial),
                  onChanged: (value) {
                    appState.setGpsSimulatorSpeed(value);
                  },
                ),
                trailing: Text(
                  formatSpeed(appState.gpsSimulatorSpeed,
                      isImperial: prefs.isImperial),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('Simulation Altitude'),
                subtitle: Slider(
                  value: appState.gpsSimulatorAltitude,
                  min: 0,
                  max: 12000,
                  divisions: 12,
                  label: formatMeters(appState.gpsSimulatorAltitude,
                      isImperial: prefs.isImperial),
                  onChanged: (value) {
                    appState.setGpsSimulatorAltitude(value);
                  },
                ),
                trailing: Text(
                  formatMeters(appState.gpsSimulatorAltitude,
                      isImperial: prefs.isImperial),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
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
                        child: Text('Straight Line',
                            overflow: TextOverflow.ellipsis),
                      ),
                      const DropdownMenuItem(
                        value: SimulatorPattern.circle,
                        child: Text('Circle', overflow: TextOverflow.ellipsis),
                      ),
                      const DropdownMenuItem(
                        value: SimulatorPattern.randomWalk,
                        child: Text('Random Walk',
                            overflow: TextOverflow.ellipsis),
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
          ]),
        ],
      ),
    );
  }

  Future<void> _pickRouteFile(
      BuildContext context, AppStateProvider appState) async {
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
          final content =
              file.bytes != null ? String.fromCharCodes(file.bytes!) : null;

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

  void _processRouteFile(BuildContext context, AppStateProvider appState,
      String content, String filename) {
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
}
