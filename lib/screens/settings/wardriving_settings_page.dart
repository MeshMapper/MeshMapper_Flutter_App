import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/connection_state.dart';
import '../../models/user_preferences.dart';
import '../../providers/app_state_provider.dart';
import '../../widgets/app_toast.dart';
import 'settings_section_card.dart';

/// Settings folder: Wardriving.
class WardrivingSettingsPage extends StatelessWidget {
  const WardrivingSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final prefs = appState.preferences;
    final isAutoMode = appState.autoPingEnabled;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Wardriving', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          if (isAutoMode) const AutoPingLockBanner(),

          // Privacy
          SettingsSectionCard(title: 'Privacy', children: [
            SwitchListTile(
              secondary: const Icon(Icons.visibility_off),
              title: const Text('Anonymous Mode'),
              subtitle: Text(prefs.anonymousMode
                  ? 'Device broadcasts as "Anonymous"'
                  : 'Device uses its real name'),
              value: prefs.anonymousMode,
              onChanged: isAutoMode
                  ? null
                  : (value) {
                      if (value) {
                        _showEnableAnonymousConfirmation(context, appState);
                      } else {
                        if (appState.connectionStatus ==
                            ConnectionStatus.connected) {
                          _showDisableAnonymousConfirmation(context, appState);
                        } else {
                          appState.setAnonymousMode(false);
                        }
                      }
                    },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.my_location),
              title: const Text('Broadcast My Coordinates'),
              subtitle: Text(prefs.broadcastCoords
                  ? 'Real GPS is sent on the air'
                  : 'Coordinates stay private (sent only to the server)'),
              value: prefs.broadcastCoords,
              onChanged: (value) => appState.setBroadcastCoords(value),
            ),
          ]),

          // Auto-ping timing
          SettingsSectionCard(title: 'Auto-Ping', children: [
            ListTile(
              leading: const Icon(Icons.timer),
              title: const Text('Auto-Ping Interval'),
              subtitle: Text(prefs.autoPingIntervalDisplay),
              trailing: const Icon(Icons.chevron_right),
              enabled: !isAutoMode,
              onTap: isAutoMode
                  ? null
                  : () => _showIntervalSelector(context, appState),
            ),
            ListTile(
              leading: const Icon(Icons.straighten),
              title: const Text('Min Ping Distance'),
              subtitle: Text(prefs.minPingDistanceDisplay),
              trailing: const Icon(Icons.chevron_right),
              enabled: !isAutoMode,
              onTap: isAutoMode
                  ? null
                  : () => _showDistanceSelector(context, appState),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.auto_awesome),
              title: const Text('Smart Pinging'),
              subtitle: appState.enforceSmartPing
                  ? const Text(
                      'Set by Regional Admin. Skips squares that already have recent coverage.',
                      style: TextStyle(color: Colors.amber),
                    )
                  : const Text(
                      'Skip squares that already have recent coverage'),
              value: appState.smartPingEnabled,
              onChanged: (isAutoMode || appState.enforceSmartPing)
                  ? null
                  : (value) {
                      appState.updatePreferences(
                          prefs.copyWith(smartPingEnabled: value));
                    },
            ),
            if (appState.smartPingEnabled)
              ListTile(
                leading: const Icon(Icons.history),
                title: const Text('Skip squares covered within'),
                subtitle: Text(appState.enforceSmartPing
                    ? '${_smartPingDaysLabel(appState.smartPingDays)} (set by Regional Admin)'
                    : _smartPingDaysLabel(prefs.smartPingDays)),
                trailing: const Icon(Icons.chevron_right),
                enabled: !isAutoMode && !appState.enforceSmartPing,
                onTap: (isAutoMode || appState.enforceSmartPing)
                    ? null
                    : () => _showSmartPingDaysSelector(context, appState),
              ),
            SwitchListTile(
              secondary: const Icon(Icons.timer_off),
              title: const Text('Auto-Stop After Idle'),
              subtitle:
                  const Text('Stops auto-ping after 30 min without movement'),
              value: prefs.autoStopAfterIdle,
              onChanged: isAutoMode
                  ? null
                  : (value) {
                      appState.updatePreferences(
                          prefs.copyWith(autoStopAfterIdle: value));
                    },
            ),
          ]),

          // CARpeater filtering
          SettingsSectionCard(title: 'CARpeater', children: [
            SwitchListTile(
              secondary: const Icon(Icons.filter_alt),
              title: const Text('CARpeater Filter'),
              subtitle: Text(
                  prefs.ignoreCarpeater && prefs.ignoreRepeaterId != null
                      ? 'Pass-through: stripping 0x${prefs.ignoreRepeaterId}'
                      : 'Tap to set CARpeater repeater ID'),
              value: prefs.ignoreCarpeater,
              onChanged: isAutoMode
                  ? null
                  : (value) {
                      if (value && prefs.ignoreRepeaterId == null) {
                        _showRepeaterIdDialog(context, appState);
                      } else {
                        appState.updatePreferences(
                            prefs.copyWith(ignoreCarpeater: value));
                      }
                    },
            ),
            if (prefs.ignoreCarpeater)
              ListTile(
                leading: const SizedBox(width: 24),
                title: const Text('CARpeater ID'),
                subtitle: Text(prefs.ignoreRepeaterId != null
                    ? '0x${prefs.ignoreRepeaterId}'
                    : 'Not set'),
                trailing: const Icon(Icons.chevron_right),
                enabled: !isAutoMode,
                onTap: isAutoMode
                    ? null
                    : () => _showRepeaterIdDialog(context, appState),
              ),
            SwitchListTile(
              secondary: const Icon(Icons.shield_outlined),
              title: const Text('Disable RSSI Filter'),
              subtitle: Text(prefs.disableRssiFilter
                  ? 'Allows all signal strengths'
                  : 'Drops signals stronger than -30 dBm'),
              value: prefs.disableRssiFilter,
              onChanged: isAutoMode
                  ? null
                  : (value) {
                      if (value) {
                        _showDisableRssiFilterConfirmation(context, appState);
                      } else {
                        appState.updatePreferences(
                            prefs.copyWith(disableRssiFilter: false));
                      }
                    },
            ),
          ]),

          // Modes
          SettingsSectionCard(title: 'Modes', children: [
            SwitchListTile(
              secondary: const Icon(Icons.waves),
              title: const Text('Flood Traffic'),
              subtitle: appState.floodDisabled
                  ? const Text(
                      'Set by Regional Admin. Flood traffic is turned off here, so '
                      'Active and Hybrid modes are unavailable. Passive and Trace '
                      'still work.',
                      style: TextStyle(color: Colors.blue),
                    )
                  : const Text(
                      'Show Active, Hybrid, and manual Send Ping controls'),
              value: appState.floodDisabled ? false : prefs.floodTrafficEnabled,
              onChanged: (isAutoMode || appState.floodDisabled)
                  ? null
                  : (value) {
                      appState.updatePreferences(
                          prefs.copyWith(floodTrafficEnabled: value));
                    },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.compare_arrows),
              title: Row(
                children: [
                  const Flexible(
                      child:
                          Text('Hybrid Mode', overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => _showHybridModeInfo(context),
                    icon: Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
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
              onChanged: (isAutoMode || appState.enforceHybrid)
                  ? null
                  : (value) {
                      appState.updatePreferences(
                          prefs.copyWith(hybridModeEnabled: value));
                    },
            ),
            SwitchListTile(
              secondary: const Icon(Icons.signal_wifi_off),
              title: Row(
                children: [
                  const Flexible(
                      child: Text('Discovery Drop',
                          overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => _showDiscDropInfo(context),
                    icon: Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              subtitle: appState.enforceDiscDrop
                  ? const Text(
                      'Set by Regional Admin — reports dead zones for network analysis.',
                      style: TextStyle(color: Colors.amber),
                    )
                  : const Text('Count failed discoveries as failed pings'),
              value: appState.enforceDiscDrop ? true : prefs.discDropEnabled,
              onChanged: (isAutoMode || appState.enforceDiscDrop)
                  ? null
                  : (value) {
                      if (value == true) {
                        _showDiscDropEnableConfirmation(context, appState);
                      } else {
                        appState.updatePreferences(
                            prefs.copyWith(discDropEnabled: false));
                      }
                    },
            ),
          ]),

          // Radio Settings
          SettingsSectionCard(title: 'Radio', children: [
            ListTile(
              leading: const Icon(Icons.linear_scale),
              title: Row(
                children: [
                  const Flexible(
                      child: Text('TX Bytes', overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => _showHopBytesInfo(context),
                    icon: Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              subtitle: appState.enforceHopBytes
                  ? const Text(
                      'Set by Regional Admin — larger IDs reduce collisions in your region.',
                      style: TextStyle(color: Colors.amber),
                    )
                  : (appState.isConnected && !appState.supportsMultiBytePaths)
                      ? const Text(
                          'Firmware 1.14+ required',
                          style: TextStyle(color: Colors.amber),
                        )
                      : !appState.isConnected
                          ? const Text(
                              'Connect to radio to configure',
                              style: TextStyle(color: Colors.amber),
                            )
                          : const Text('Repeater ID size in TX/RX path hops'),
              trailing: DropdownButton<int>(
                value: appState.enforceHopBytes
                    ? appState.effectiveHopBytes
                    : appState.hopBytes,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1')),
                  DropdownMenuItem(value: 2, child: Text('2')),
                  DropdownMenuItem(value: 3, child: Text('3')),
                ],
                onChanged: (!appState.isConnected ||
                        isAutoMode ||
                        appState.enforceHopBytes ||
                        !appState.supportsMultiBytePaths)
                    ? null
                    : (value) {
                        if (value != null) appState.setHopBytes(value);
                      },
              ),
            ),
            ListTile(
              leading: const Icon(Icons.gps_fixed),
              title: Row(
                children: [
                  const Flexible(
                      child:
                          Text('Trace Bytes', overflow: TextOverflow.ellipsis)),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => _showTraceBytesInfo(context),
                    icon: Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              subtitle: !appState.isConnected
                  ? const Text(
                      'Connect to radio to configure',
                      style: TextStyle(color: Colors.amber),
                    )
                  : (appState.isConnected && !appState.supportsMultiBytePaths)
                      ? const Text(
                          'Firmware 1.14+ required',
                          style: TextStyle(color: Colors.amber),
                        )
                      : const Text('Repeater ID size in trace path'),
              trailing: DropdownButton<int>(
                value: appState.traceHopBytes,
                underline: const SizedBox(),
                items: const [
                  DropdownMenuItem(value: 1, child: Text('1')),
                  DropdownMenuItem(value: 2, child: Text('2')),
                  DropdownMenuItem(value: 4, child: Text('4')),
                ],
                onChanged: (!appState.isConnected ||
                        isAutoMode ||
                        !appState.supportsMultiBytePaths)
                    ? null
                    : (value) {
                        if (value != null) appState.setTraceHopBytes(value);
                      },
              ),
            ),
            SwitchListTile(
              secondary: const Icon(Icons.delete_sweep),
              title: Row(
                children: [
                  const Flexible(child: Text('Delete Channel on Disconnect')),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: () => _showDeleteChannelInfo(context),
                    icon: Icon(
                      Icons.info_outline,
                      size: 18,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                    visualDensity: VisualDensity.compact,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              subtitle: Text(prefs.deleteChannelOnDisconnect
                  ? 'Removes #wardriving channel from device'
                  : 'Keeps #wardriving channel on device'),
              value: prefs.deleteChannelOnDisconnect,
              onChanged: (value) {
                appState.updatePreferences(
                    prefs.copyWith(deleteChannelOnDisconnect: value));
              },
            ),
          ]),
        ],
      ),
    );
  }

  void _showDisableRssiFilterConfirmation(
      BuildContext context, AppStateProvider appState) {
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

  void _showEnableAnonymousConfirmation(
      BuildContext context, AppStateProvider appState) {
    final isConnected = appState.connectionStatus == ConnectionStatus.connected;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enable Anonymous Mode?'),
        content: Text(
          'Your device will be renamed to "Anonymous" for all mesh pings. '
          'Other mesh users will not see your companion name, and you will '
          'not appear on the public leaderboard.\n\n'
          'Your public key is still sent to authenticate your session, and '
          'your sessions and pings are still recorded against it. Anonymous '
          'Mode hides your name. It does not hide your device.\n\n'
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

  void _showDisableAnonymousConfirmation(
      BuildContext context, AppStateProvider appState) {
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
            Text('How it works:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 4),
            Text(
              'Discovery \u2192 wait \u2192 TX Ping \u2192 wait \u2192 Discovery \u2192 ...',
              style: TextStyle(fontSize: 13, fontFamily: 'monospace'),
            ),
            SizedBox(height: 12),
            Text('Interval timing:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            SizedBox(height: 4),
            Text(
              'At 15s interval, each ping type fires every 30s. Discovery\'s 30s firmware rate limit is naturally respected.',
              style: TextStyle(fontSize: 13),
            ),
            SizedBox(height: 12),
            Text('When enabled:',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
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

  void _showDiscDropInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.signal_wifi_off, size: 24),
            SizedBox(width: 8),
            Text('Discovery Drop'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'When enabled, failed discovery requests (no repeater responded) are reported to the API as failed pings, helping identify dead zones in the mesh network.',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 12),
            Text(
              'Discovery requests require Repeater firmware 1.10+. If the majority of the mesh is not on this version, it may produce false "no coverage" areas/failed pings.',
              style: TextStyle(fontSize: 13, color: Colors.amber),
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

  void _showDiscDropEnableConfirmation(
      BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.signal_wifi_off, size: 24),
            SizedBox(width: 8),
            Text('Discovery Drop'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'When enabled, failed discovery requests (no repeater responded) are reported to the API as failed pings, helping identify dead zones in the mesh network.',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 12),
            Text(
              'Discovery requests require Repeater firmware 1.10+. If the majority of the mesh is not on this version, it may produce false "no coverage" areas/failed pings.',
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
                appState.preferences.copyWith(discDropEnabled: true),
              );
            },
            child: const Text('Enable'),
          ),
        ],
      ),
    );
  }

  void _showDeleteChannelInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.delete_sweep, size: 24),
            SizedBox(width: 8),
            Flexible(child: Text('Delete Channel on Disconnect')),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'When enabled, the #wardriving channel is removed from your radio when you disconnect. '
              'This keeps your radio\'s channel list clean.\n\n'
              'When disabled, the channel remains on the radio after disconnect.',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 12),
            Text(
              'If the app crashes or BLE disconnects unexpectedly, your device '
              'may retain the #wardriving channel until you reconnect and properly disconnect.',
              style: TextStyle(fontSize: 13, color: Colors.amber),
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

  void _showHopBytesInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.linear_scale, size: 24),
            SizedBox(width: 8),
            Text('TX Bytes'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Controls how many bytes are used to identify each repeater in TX/RX packet paths. '
              'More bytes = more unique IDs, reducing collisions in large networks.',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 12),
            Text(
              '\u2022 1 byte: 256 unique IDs (default)\n'
              '\u2022 2 bytes: 65,536 unique IDs\n'
              '\u2022 3 bytes: 16 million unique IDs',
              style: TextStyle(fontSize: 13),
            ),
            SizedBox(height: 12),
            Text(
              'Requires MeshCore firmware v1.14.0+. '
              'RX always auto-detects the sender\'s byte size.',
              style: TextStyle(fontSize: 13, color: Colors.amber),
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

  void _showTraceBytesInfo(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.gps_fixed, size: 24),
            SizedBox(width: 8),
            Text('Trace Bytes'),
          ],
        ),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Controls how many bytes are used for the repeater ID in trace path requests. '
              'This is separate from TX Bytes because traces use a different encoding.',
              style: TextStyle(fontSize: 14),
            ),
            SizedBox(height: 12),
            Text(
              'TX/RX uses a simple counter:\n'
              '\u2022 Mode 0 \u2192 1 byte\n'
              '\u2022 Mode 1 \u2192 2 bytes\n'
              '\u2022 Mode 2 \u2192 3 bytes\n\n'
              'Trace uses bitshift encoding:\n'
              '\u2022 Mode 0 \u2192 1 byte\n'
              '\u2022 Mode 1 \u2192 2 bytes\n'
              '\u2022 Mode 2 \u2192 4 bytes',
              style: TextStyle(fontSize: 13),
            ),
            SizedBox(height: 12),
            Text(
              '3-byte traces are not supported by the MeshCore protocol. '
              'When your region uses 3-byte TX paths, set Trace Bytes to 4.',
              style: TextStyle(fontSize: 13, color: Colors.amber),
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
                title: Text(
                  '$interval seconds',
                  style: const TextStyle(
                      fontSize: 17, fontWeight: FontWeight.bold),
                ),
                subtitle: isDisabled
                    ? const Text(
                        'Set by Regional Admin — slower intervals reduce congestion in your region',
                        style: TextStyle(fontSize: 12, color: Colors.amber),
                      )
                    : Text(
                        description,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
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

  void _showDistanceSelector(BuildContext context, AppStateProvider appState) {
    final currentDistance = appState.preferences.minPingDistanceMeters;
    final controller = TextEditingController(text: currentDistance.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Min Ping Distance'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            suffixText: 'meters',
            helperText: 'Minimum ${MinPingDistance.min}m',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text);
              if (value != null && value >= MinPingDistance.min) {
                appState.updatePreferences(
                  appState.preferences.copyWith(minPingDistanceMeters: value),
                );
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  String _smartPingDaysLabel(int days) => days == 1 ? '1 day' : '$days days';

  void _showSmartPingDaysSelector(
      BuildContext context, AppStateProvider appState) {
    final controller = TextEditingController(
        text: appState.preferences.smartPingDays.toString());

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Skip squares covered within'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            suffixText: 'days',
            helperText: '${SmartPingDays.min} to ${SmartPingDays.max} days',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final value = int.tryParse(controller.text.trim());
              if (value != null &&
                  value >= SmartPingDays.min &&
                  value <= SmartPingDays.max) {
                appState.updatePreferences(
                  appState.preferences.copyWith(smartPingDays: value),
                );
                Navigator.pop(context);
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _showRepeaterIdDialog(BuildContext context, AppStateProvider appState) {
    const maxHexChars = 6;
    const hintText = 'FFFFFF';

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
            const Text('Enter the full 3-byte repeater ID (6 hex digits):'),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'CARpeater ID',
                hintText: hintText,
                prefixText: '0x',
                border: OutlineInputBorder(),
              ),
              maxLength: maxHexChars,
              textCapitalization: TextCapitalization.characters,
              onChanged: (value) {
                // Keep only valid hex characters
                final filtered =
                    value.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
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
              'Enter all 6 hex digits of your CARpeater\'s ID. '
              'The app will automatically truncate to match your region\'s hop byte size (1, 2, or 3 bytes). '
              'Multi-hop packets through your CARpeater will be stripped to report the underlying repeater.',
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
                  (value.length == maxHexChars &&
                      RegExp(r'^[0-9A-F]+$').hasMatch(value));

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
                AppToast.warning(
                    context, 'Please enter exactly 6 hex digits (3-byte ID).');
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}
