import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/connection_state.dart';
import '../models/remembered_device.dart';
import '../models/user_preferences.dart';
import '../providers/app_state_provider.dart';
import '../utils/distance_formatter.dart';
import '../services/bluetooth/bluetooth_service.dart';
import '../widgets/regional_config_card.dart';

/// BLE device selection and connection screen
class ConnectionScreen extends StatefulWidget {
  const ConnectionScreen({super.key});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

class _ConnectionScreenState extends State<ConnectionScreen> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // Re-check GPS when app returns from settings (permission denied or location disabled)
      final appState = context.read<AppStateProvider>();
      if (appState.gpsStatus == GpsStatus.permissionDenied ||
          appState.gpsStatus == GpsStatus.disabled) {
        appState.restartGpsAfterPermission();
      }
    }
  }

  /// Request location permission - tries to request first, opens settings if permanently denied
  Future<void> _requestLocationPermission(AppStateProvider appState) async {
    // Check current permission status
    LocationPermission permission = await Geolocator.checkPermission();

    // If denied (not permanently), try requesting again
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    // If permanently denied, open app settings
    if (permission == LocationPermission.deniedForever) {
      await Geolocator.openAppSettings();
      return;
    }

    // If granted, restart GPS service
    if (permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse) {
      await appState.restartGpsAfterPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    // Build FAB for scanning - show Cancel during scan, Scan when idle
    // Hide FAB entirely during maintenance mode (maintenance UI has its own buttons)
    // Hide FAB when Bluetooth is off (shows full-screen message instead)
    // Hide FAB during auto-reconnect
    Widget? fab;
    if (appState.isScanning) {
      // Show Cancel FAB during active scan
      fab = isLandscape
          ? FloatingActionButton.small(
              onPressed: () => appState.stopScan(),
              backgroundColor: Colors.red,
              child: const Icon(Icons.close),
            )
          : FloatingActionButton.extended(
              onPressed: () => appState.stopScan(),
              icon: const Icon(Icons.close),
              label: const Text('Cancel'),
              backgroundColor: Colors.red,
            );
    } else if (appState.connectionStep == ConnectionStep.disconnected &&
        !appState.isAutoReconnecting &&
        (!appState.maintenanceMode || appState.offlineMode) &&
        !appState.isBluetoothOff) {
      // Offline mode bypasses both zone and maintenance checks
      final canScan = appState.offlineMode || appState.inZone == true;
      fab = isLandscape
          ? FloatingActionButton.small(
              onPressed: canScan ? () => appState.startScan() : null,
              backgroundColor: canScan ? null : Colors.grey,
              child: const Icon(Icons.bluetooth_searching),
            )
          : FloatingActionButton.extended(
              onPressed: canScan ? () => appState.startScan() : null,
              icon: const Icon(Icons.bluetooth_searching),
              label: Text(appState.offlineMode
                  ? 'Scan'
                  : appState.gpsStatus == GpsStatus.disabled
                      ? 'GPS Disabled'
                      : appState.gpsStatus == GpsStatus.permissionDenied
                          ? 'GPS Required'
                          : appState.isCheckingZone
                              ? 'Checking Zone...'
                              : appState.inZone == true
                                  ? 'Scan'
                                  : appState.inZone == false
                                      ? 'Outside Zone'
                                      : 'Checking Zone...'),
              backgroundColor: canScan ? null : Colors.grey,
            );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Connection'),
        automaticallyImplyLeading: false,
      ),
      body: _buildBody(context, appState),
      floatingActionButton: fab,
    );
  }

  Widget _buildBody(BuildContext context, AppStateProvider appState) {
    // Show reconnecting UI
    if (appState.connectionStep == ConnectionStep.reconnecting) {
      return _buildReconnectingView(context, appState);
    }

    // Show connection progress
    if (appState.connectionStep != ConnectionStep.disconnected &&
        appState.connectionStep != ConnectionStep.connected &&
        appState.connectionStep != ConnectionStep.error) {
      return _buildConnectionProgress(context, appState);
    }

    // Show connected state
    if (appState.isConnected) {
      // Show path hash mode warning popup if pending
      final pathWarning = appState.pendingPathHashWarning;
      if (pathWarning != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _showPathHashWarning(context, pathWarning.hopBytes, pathWarning.reason);
          appState.clearPathHashWarning();
        });
      }
      return _buildConnectedInfo(context, appState);
    }

    // Show error
    if (appState.connectionError != null) {
      return _buildError(context, appState);
    }

    // Show device list
    return _buildDeviceList(context, appState);
  }

  Widget _buildConnectionProgress(BuildContext context, AppStateProvider appState) {
    final step = appState.connectionStep;
    final totalSteps = ConnectionStepExtension.totalSteps;
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return SafeArea(
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(isLandscape ? 16 : 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              SizedBox(height: isLandscape ? 12 : 24),
              Text(
                step.description,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              SizedBox(
                width: isLandscape ? 300 : double.infinity,
                child: LinearProgressIndicator(
                  value: step.stepNumber / totalSteps,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Step ${step.stepNumber} of $totalSteps',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildReconnectingView(BuildContext context, AppStateProvider appState) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;
    final deviceName = appState.rememberedDevice?.displayName ?? 'device';

    return SafeArea(
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(isLandscape ? 16 : 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              SizedBox(height: isLandscape ? 12 : 24),
              Text(
                'Reconnecting...',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                'Attempt ${appState.reconnectAttempt} of 3',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                deviceName,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
              ),
              SizedBox(height: isLandscape ? 16 : 24),
              OutlinedButton(
                onPressed: () => appState.cancelAutoReconnect(),
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildConnectedInfo(BuildContext context, AppStateProvider appState) {
    // Get device name - uses displayDeviceName which prefers SelfInfo name over BLE advertisement name
    final deviceName = appState.displayDeviceName ?? 'Unknown';

    // Parse version from manufacturer string and use shortName from device model for hardware
    // Format examples:
    // - "MeshCore (Heltec V3) v1.10.0"
    // - "Ikoka Stick-E22-30dBm (Xiao_nrf52)      nightly-e31c46f"
    String? version;
    final manufacturerString = appState.manufacturerString;
    if (manufacturerString != null) {
      // Use regex to find version pattern directly instead of splitting
      // Match: v followed by digits/dots, OR nightly- followed by hex, OR just digits.digits
      final versionRegex = RegExp(r'(v[\d.]+|nightly-[a-f0-9]+|\d+\.\d+\.\d+)');
      final match = versionRegex.firstMatch(manufacturerString);
      if (match != null) {
        version = match.group(1);
      }
    }

    // Use shortName from device model if available, otherwise fall back to manufacturer string
    final hardware = appState.deviceModel?.shortName ?? manufacturerString ?? 'Unknown';

    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    // Build device info card
    final deviceInfoCard = Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.bluetooth_connected,
                  color: Colors.green,
                  size: 28,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connected',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: Colors.green,
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      Text(
                        deviceName,
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const Divider(height: 20),
            _buildInfoRow('Hardware', hardware),
            _buildInfoRow('Version', version ?? 'Unknown'),
            if (appState.deviceModel != null)
              _buildInfoRow('Platform', appState.deviceModel!.platform),
            if (appState.devicePublicKey != null)
              _buildPublicKeyRow(context, appState.devicePublicKey!),
            if (appState.authType != null && !appState.offlineMode)
              _buildAuthTypeRow(context, appState.authType!),
          ],
        ),
      ),
    );

    // Build disconnect button
    final disconnectButton = ElevatedButton.icon(
      onPressed: () async {
        await appState.disconnect();
      },
      icon: const Icon(Icons.bluetooth_disabled),
      label: const Text('Disconnect'),
      style: ElevatedButton.styleFrom(
        backgroundColor: Colors.red,
        foregroundColor: Colors.white,
      ),
    );

    if (isLandscape) {
      // Landscape: two-column layout
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left column: device info + disconnect
              Expanded(
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: deviceInfoCard,
                      ),
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: disconnectButton,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Right column: power + regional config
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      _buildPowerLevelCard(context, appState),
                      const SizedBox(height: 12),
                      RegionalConfigCard(
                        zoneName: appState.offlineMode ? null : appState.zoneName,
                        zoneCode: appState.offlineMode ? null : appState.zoneCode,
                        channels: appState.offlineMode ? [] : appState.regionalChannels,
                        scope: appState.offlineMode ? null : appState.scope,
                        isOfflineMode: appState.offlineMode,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // Portrait: vertical layout
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              deviceInfoCard,
              const SizedBox(height: 16),
              _buildPowerLevelCard(context, appState),
              const SizedBox(height: 16),
              RegionalConfigCard(
                zoneName: appState.offlineMode ? null : appState.zoneName,
                zoneCode: appState.offlineMode ? null : appState.zoneCode,
                channels: appState.offlineMode ? [] : appState.regionalChannels,
                scope: appState.offlineMode ? null : appState.scope,
                isOfflineMode: appState.offlineMode,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: disconnectButton,
          ),
        ),
      ],
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildPublicKeyRow(BuildContext context, String publicKey) {
    // Show truncated key for display (first 8 + ... + last 8)
    final displayKey = publicKey.length > 16
        ? '${publicKey.substring(0, 8)}...${publicKey.substring(publicKey.length - 8)}'
        : publicKey;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          const SizedBox(
            width: 120,
            child: Text(
              'Public Key',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: publicKey));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Public key copied to clipboard'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      displayKey,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      Icons.copy,
                      size: 14,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAuthTypeRow(BuildContext context, String authType) {
    // Icon and color based on auth type
    IconData icon;
    Color color;
    String displayText;

    switch (authType) {
      case 'API':
        icon = Icons.cloud_done;
        color = Colors.blue;
        displayText = 'API';
      case 'Mesh':
        icon = Icons.cell_tower;
        color = Colors.green;
        displayText = 'Mesh';
      case 'Manual':
        icon = Icons.person;
        color = Colors.orange;
        displayText = 'Manual';
      default:
        icon = Icons.verified_user;
        color = Colors.grey;
        displayText = authType;
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: () => _showAuthMethodInfo(context, authType),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            children: [
              const SizedBox(
                width: 120,
                child: Text(
                  'Registered via',
                  style: TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16, color: color),
                  const SizedBox(width: 4),
                  Text(
                    displayText,
                    style: TextStyle(
                      color: color,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.info_outline, size: 14, color: Colors.grey),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showAuthMethodInfo(BuildContext context, String currentType) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surfaceContainerHighest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header with close button
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.blue.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: Colors.blue.withValues(alpha: 0.4)),
                    ),
                    child: const Icon(Icons.verified_user, color: Colors.blue, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Registration Methods',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Content
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildAuthMethodItem(
                      context: context,
                      icon: Icons.cell_tower,
                      color: Colors.green,
                      title: 'Mesh',
                      trustLevel: 'Most trusted',
                      description: 'Your companion\'s signed advert was heard over the mesh by a LetsMesh Observer and collected via MQTT. This confirms your radio is actively participating in the network.',
                      isCurrentType: currentType == 'Mesh',
                    ),
                    const SizedBox(height: 12),
                    _buildAuthMethodItem(
                      context: context,
                      icon: Icons.cloud_done,
                      color: Colors.blue,
                      title: 'API',
                      trustLevel: 'Trusted',
                      description: 'We registered your companion using a signed advert via the MeshMapper API. We haven\'t heard you over the mesh yet, but your device identity is verified.',
                      isCurrentType: currentType == 'API',
                    ),
                    const SizedBox(height: 12),
                    _buildAuthMethodItem(
                      context: context,
                      icon: Icons.person,
                      color: Colors.orange,
                      title: 'Manual',
                      trustLevel: 'Basic',
                      description: 'An administrator manually added your device. Go wardriving to upgrade to Mesh verification!',
                      isCurrentType: currentType == 'Manual',
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAuthMethodItem({
    required BuildContext context,
    required IconData icon,
    required Color color,
    required String title,
    required String trustLevel,
    required String description,
    required bool isCurrentType,
  }) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isCurrentType ? color.withValues(alpha: 0.1) : null,
        borderRadius: BorderRadius.circular(8),
        border: isCurrentType ? Border.all(color: color.withValues(alpha: 0.4)) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      trustLevel,
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                      ),
                    ),
                    if (isCurrentType) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: color,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'Current',
                          style: TextStyle(
                            fontSize: 10,
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPowerLevelCard(BuildContext context, AppStateProvider appState) {
    final prefs = appState.preferences;
    final isAutoMode = appState.autoPingEnabled;
    final isPowerSet = prefs.autoPowerSet || prefs.powerLevelSet || appState.deviceModel != null;

    return Card(
      child: ListTile(
        leading: const Icon(Icons.power),
        title: const Text('Power Level'),
        subtitle: Builder(
          builder: (context) {
            if (!isPowerSet) {
              return Text(
                'Unknown hardware - select power',
                style: TextStyle(color: Colors.orange.shade700),
              );
            }
            return Row(
              children: [
                Text(prefs.powerLevelDisplay),
                if (prefs.autoPowerSet) ...[
                  const SizedBox(width: 8),
                  const Icon(Icons.auto_awesome, size: 14, color: Colors.green),
                  const SizedBox(width: 4),
                  const Text(
                    'Auto',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ],
            );
          },
        ),
        trailing: const Icon(Icons.chevron_right),
        enabled: !isAutoMode,
        onTap: isAutoMode ? null : () => _showPowerLevelSelector(context, appState),
      ),
    );
  }

  void _showPowerLevelSelector(BuildContext context, AppStateProvider appState) {
    final prefs = appState.preferences;
    final deviceModel = appState.deviceModel;
    // Only show selection if power has been set (auto or manual)
    final isPowerSet = prefs.autoPowerSet || prefs.powerLevelSet || deviceModel != null;
    final currentPower = isPowerSet ? prefs.powerLevel : null;

    // Helper to handle power selection with confirmation for overrides
    void selectPower(double value) {
      final isOverride = prefs.autoPowerSet && deviceModel != null;

      // Show override confirmation if changing auto-detected power
      if (isOverride && value != deviceModel.power) {
        showDialog(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Override Auto-Detected Power?'),
            content: Text(
              'This device was auto-detected as "${deviceModel.shortName}" '
              'which reports ${deviceModel.power}W.\n\n'
              'Are you sure you want to report ${value}W instead?',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () {
                  appState.updatePreferences(
                    prefs.copyWith(
                      powerLevel: value,
                      txPower: PowerLevel.getTxPower(value),
                      autoPowerSet: false, // Clear auto flag on override
                    ),
                  );
                  Navigator.pop(context); // Close confirmation
                  Navigator.pop(context); // Close power selector
                },
                child: const Text('Override'),
              ),
            ],
          ),
        );
      } else {
        // Direct selection (no auto-power or same value)
        appState.updatePreferences(
          prefs.copyWith(
            powerLevel: value,
            txPower: PowerLevel.getTxPower(value),
            autoPowerSet: false,
            powerLevelSet: true,  // Mark as manually set
          ),
        );
        Navigator.pop(context);
      }
    }

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Select Power Level'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Auto-detection info banner
            if (prefs.autoPowerSet && deviceModel != null)
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: Colors.green.withValues(alpha: 0.1),
                  border: Border.all(color: Colors.green),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.auto_awesome, size: 20, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Auto-detected: ${deviceModel.shortName} ${deviceModel.power}W',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),

            // Power level options
            RadioGroup<double>(
              groupValue: currentPower ?? -1,
              onChanged: (value) {
                if (value != null) {
                  selectPower(value);
                }
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: PowerLevel.values.map((power) {
                  final isSelected = power == currentPower;
                  final isRecommended = prefs.autoPowerSet && deviceModel != null && power == deviceModel.power;

                  // Create a temp preferences object to get the display string with dBm
                  final tempPrefs = UserPreferences(powerLevel: power);

                  return RadioListTile<double>(
                    title: Row(
                      children: [
                        Flexible(child: Text(tempPrefs.powerLevelDisplayWithDbm)),
                        if (isRecommended) ...[
                          const SizedBox(width: 8),
                          const Icon(Icons.check_circle, size: 16, color: Colors.green),
                        ],
                      ],
                    ),
                    value: power,
                    selected: isSelected,
                  );
                }).toList(),
              ),
            ),

            // Info note
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.blue.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline, size: 16, color: Colors.blue),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'This setting is used for reporting your radio\'s power level in wardriving data. It does not change your radio\'s actual output.',
                      style: TextStyle(fontSize: 11, color: Colors.blue[800]),
                    ),
                  ),
                ],
              ),
            ),
          ],
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

  Widget _buildError(BuildContext context, AppStateProvider appState) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return SafeArea(
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(isLandscape ? 16 : 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.error_outline,
                size: isLandscape ? 48 : 64,
                color: Colors.red,
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              Text(
                appState.isAuthError ? 'Authentication Failed' : 'Connection Failed',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                appState.connectionError ?? 'Unknown error',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              SizedBox(height: isLandscape ? 12 : 24),
              ElevatedButton.icon(
                onPressed: () => appState.startScan(),
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Builds a compact zone status bar matching StatusBar design
  Widget _buildZoneStatusBar(BuildContext context, AppStateProvider appState) {
    final theme = Theme.of(context);

    // Determine zone status
    IconData locationIcon;
    String locationText;
    String? iataCode;
    Color locationColor;

    // Offline mode: show greyed out with "-"
    if (appState.offlineMode) {
      locationIcon = Icons.gps_off;
      locationText = '-';
      locationColor = Colors.grey;
    // Check maintenance mode
    } else if (appState.maintenanceMode) {
      locationIcon = Icons.engineering;
      locationText = 'Maintenance';
      locationColor = Colors.orange;
    // Network error: show wifi off indicator
    } else if (appState.zoneCheckErrorReason == 'network') {
      locationIcon = Icons.wifi_off;
      locationText = 'No Internet';
      locationColor = Colors.red;
    // Show "Checking Zone..." whenever a zone check is in progress
    // This provides consistent UI feedback during both initial and re-checks
    } else if (appState.isCheckingZone) {
      locationIcon = Icons.location_searching;
      locationText = 'Checking Zone...';
      locationColor = Colors.blue;
    } else if (appState.inZone == true) {
      locationIcon = Icons.location_on;
      locationText = appState.zoneName ?? 'Unknown';
      iataCode = appState.zoneCode;
      locationColor = Colors.green;
    } else if (appState.inZone == false) {
      locationIcon = Icons.location_off;
      locationText = 'Outside Zone';
      locationColor = Colors.orange;
    } else {
      locationIcon = Icons.gps_not_fixed;
      locationText = '...';
      locationColor = Colors.grey;
    }

    // Slots info
    final slotsAvailable = appState.zoneSlotsAvailable;
    final slotsMax = appState.zoneSlotsMax;
    final hasSlots = slotsAvailable != null && slotsMax != null;

    // Slots color based on availability
    Color slotsColor;
    if (!hasSlots) {
      slotsColor = Colors.grey;
    } else if (slotsAvailable == 0) {
      slotsColor = Colors.red;
    } else if (slotsAvailable <= 2) {
      slotsColor = Colors.orange;
    } else {
      slotsColor = Colors.green;
    }

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            // Location chip (city name)
            _buildChip(
              icon: locationIcon,
              text: locationText,
              color: locationColor,
            ),

            // IATA code chip (only when in zone)
            if (iataCode != null) ...[
              const SizedBox(width: 8),
              _buildChip(
                icon: Icons.flight,
                text: iataCode,
                color: Colors.blue,
              ),
            ],

            const Spacer(),

            // Slots chip
            _buildChip(
              icon: Icons.people_outline,
              text: hasSlots ? '$slotsAvailable/$slotsMax Open' : '--',
              color: slotsColor,
            ),
          ],
        ),
      ),
    );
  }

  /// Builds a chip matching StatusBar design
  Widget _buildChip({
    required IconData icon,
    required String text,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  /// Helper to build scrollable centered message content (handles landscape overflow)
  Widget _buildMessageContent({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String message,
    Widget? action,
  }) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    // Use Center with CustomScrollView for both vertical centering and scroll capability
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: EdgeInsets.all(isLandscape ? 16 : 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: isLandscape ? 40 : 64,
                color: iconColor,
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SizedBox(height: isLandscape ? 6 : 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                    ),
              ),
              if (action != null) ...[
                SizedBox(height: isLandscape ? 12 : 24),
                action,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceList(BuildContext context, AppStateProvider appState) {
    // Offline mode bypasses both zone and maintenance checks
    final canConnect = appState.offlineMode || (appState.inZone == true && !appState.maintenanceMode);

    // Show maintenance message (takes priority over zone checks)
    if (appState.maintenanceMode && !appState.offlineMode) {
      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.engineering,
                      size: 64,
                      color: Colors.orange.withValues(alpha: 0.7),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Maintenance Mode',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      appState.maintenanceMessage ?? 'Service is temporarily unavailable.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey.shade600,
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Primary action: Enable Offline Mode
                    FilledButton.icon(
                      onPressed: () => appState.setOfflineMode(true),
                      icon: const Icon(Icons.cloud_off),
                      label: const Text('Enable Offline Mode'),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                    ),
                    if (appState.maintenanceUrl != null) ...[
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: () => _launchMaintenanceUrl(appState.maintenanceUrl!),
                        icon: const Icon(Icons.open_in_new, size: 18),
                        label: const Text('More Info'),
                      ),
                    ],
                    const SizedBox(height: 32),
                    // Info note at bottom
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.blue.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.info_outline, size: 18, color: Colors.blue.shade700),
                          const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              'Wardrive offline now, upload when service is restored.',
                              style: TextStyle(fontSize: 13, color: Colors.blue.shade700),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Show Bluetooth off message (takes priority over zone checks)
    if (appState.isBluetoothOff) {
      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          Expanded(
            child: _buildMessageContent(
              context: context,
              icon: Icons.bluetooth_disabled,
              iconColor: Colors.red.withValues(alpha: 0.7),
              title: 'Bluetooth is Off',
              message: 'Please enable Bluetooth to scan for MeshCore devices.',
            ),
          ),
        ],
      );
    }

    // Show onboarding message when outside zone (but NOT when offline mode is enabled)
    if (appState.inZone == false && !appState.offlineMode) {
      // Build message with nearest zone info if available
      final nearestName = appState.nearestZoneName;
      final nearestCode = appState.nearestZoneCode;
      final distKmValue = appState.nearestZoneDistanceKm;

      String message = 'Your geo zone is not on-boarded into MeshMapper.';
      if (nearestName != null && distKmValue != null) {
        final zoneDisplay = nearestCode != null ? '$nearestName ($nearestCode)' : nearestName;
        final dist = formatKilometers(distKmValue, isImperial: appState.preferences.isImperial);
        message += '\n\nNearest zone is $zoneDisplay, $dist away.';
      }

      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          Expanded(
            child: _buildMessageContent(
              context: context,
              icon: Icons.public_off,
              iconColor: Colors.orange.withValues(alpha: 0.7),
              title: 'Region Not Available',
              message: message,
              action: OutlinedButton.icon(
                onPressed: () => _launchOnboardingUrl(),
                icon: const Icon(Icons.open_in_new, size: 18),
                label: const Text('Request Region Onboarding'),
              ),
            ),
          ),
        ],
      );
    }

    // Show zone checking status on initial startup (before zone is known)
    if (appState.inZone == null && !appState.offlineMode) {
      if (appState.zoneCheckError != null) {
        final countdown = appState.zoneCheckRetryCountdown;

        // Network error — show offline mode option (matches maintenance pattern)
        if (appState.zoneCheckErrorReason == 'network') {
          return Column(
            children: [
              _buildZoneStatusBar(context, appState),
              Expanded(
                child: Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.wifi_off,
                          size: 64,
                          color: Colors.deepOrange.withValues(alpha: 0.7),
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'No Internet Connection',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Unable to reach MeshMapper. Check your connection, or wardrive offline.',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 14,
                            color: Colors.grey.shade600,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          countdown > 0
                              ? 'Retrying in ${countdown}s...'
                              : 'Retrying...',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.grey.shade500,
                          ),
                        ),
                        const SizedBox(height: 32),
                        FilledButton.icon(
                          onPressed: () => appState.setOfflineMode(true),
                          icon: const Icon(Icons.cloud_off),
                          label: const Text('Enable Offline Mode'),
                          style: FilledButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                          ),
                        ),
                        const SizedBox(height: 32),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: Colors.blue.withValues(alpha: 0.3)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.info_outline, size: 18, color: Colors.blue.shade700),
                              const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  'Wardrive offline now, upload when service is restored.',
                                  style: TextStyle(fontSize: 13, color: Colors.blue.shade700),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        }

        // Non-network errors — show simple error with countdown
        return Column(
          children: [
            _buildZoneStatusBar(context, appState),
            Expanded(
              child: _buildMessageContent(
                context: context,
                icon: Icons.cloud_off,
                iconColor: Colors.orange.withValues(alpha: 0.7),
                title: 'Zone Check Failed',
                message: countdown > 0
                    ? '${appState.zoneCheckError}\n\nChecking again in ${countdown}s...'
                    : '${appState.zoneCheckError}\n\nRetrying...',
              ),
            ),
          ],
        );
      }

      // Zone check in progress or waiting for GPS
      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          Expanded(
            child: _buildMessageContent(
              context: context,
              icon: Icons.location_searching,
              iconColor: Colors.blue.withValues(alpha: 0.7),
              title: 'Checking MeshMapper Zone...',
              message: 'Verifying your location with MeshMapper',
            ),
          ),
        ],
      );
    }

    if (appState.isScanning) {
      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          const LinearProgressIndicator(),
          Expanded(child: _buildDeviceListView(context, appState, canConnect: canConnect)),
        ],
      );
    }

    if (appState.discoveredDevices.isEmpty) {
      // Show remembered device option if available (mobile only)
      final remembered = appState.rememberedDevice;
      if (!kIsWeb && remembered != null) {
        return Column(
          children: [
            _buildZoneStatusBar(context, appState),
            Expanded(child: _buildRememberedDeviceView(context, appState, remembered, canConnect: canConnect)),
          ],
        );
      }

      // Show GPS disabled message when location services are off
      if (appState.gpsStatus == GpsStatus.disabled) {
        // iOS doesn't allow opening Location Services directly, so no button on iOS
        final isIOS = !kIsWeb && Platform.isIOS;

        return Column(
          children: [
            _buildZoneStatusBar(context, appState),
            Expanded(
              child: _buildMessageContent(
                context: context,
                icon: Icons.gps_off,
                iconColor: Colors.red.withValues(alpha: 0.7),
                title: 'Location Services Disabled',
                message: 'Please enable Location Services to verify you\'re in an allowed zone.',
                action: isIOS
                    ? null
                    : ElevatedButton.icon(
                        onPressed: () => Geolocator.openLocationSettings(),
                        icon: const Icon(Icons.settings),
                        label: const Text('Open Location Settings'),
                      ),
              ),
            ),
          ],
        );
      }

      // Show GPS permission required message when permissions are denied
      if (appState.gpsStatus == GpsStatus.permissionDenied) {
        return Column(
          children: [
            _buildZoneStatusBar(context, appState),
            Expanded(
              child: _buildMessageContent(
                context: context,
                icon: Icons.location_off,
                iconColor: Colors.orange.withValues(alpha: 0.7),
                title: 'GPS Permission Required',
                message: 'Location access is needed to verify you\'re in an allowed zone.',
                action: ElevatedButton.icon(
                  onPressed: () => _requestLocationPermission(appState),
                  icon: const Icon(Icons.location_on),
                  label: const Text('Enable Location'),
                ),
              ),
            ),
          ],
        );
      }

      return Column(
        children: [
          _buildZoneStatusBar(context, appState),
          Expanded(
            child: _buildMessageContent(
              context: context,
              icon: Icons.bluetooth_searching,
              iconColor: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
              title: 'No devices found',
              message: 'Tap Scan to search for MeshCore devices',
            ),
          ),
        ],
      );
    }

    return Column(
      children: [
        _buildZoneStatusBar(context, appState),
        Expanded(child: _buildDeviceListView(context, appState, canConnect: canConnect)),
      ],
    );
  }

  void _launchOnboardingUrl() async {
    final uri = Uri.parse('https://meshmapper.net/?onboarding');
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[URL] Failed to launch onboarding URL: $e');
    }
  }

  void _launchMaintenanceUrl(String url) async {
    final uri = Uri.parse(url);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      debugPrint('[URL] Failed to launch maintenance URL: $e');
    }
  }

  Widget _buildRememberedDeviceView(
    BuildContext context,
    AppStateProvider appState,
    RememberedDevice remembered, {
    bool canConnect = true,
  }) {
    final isLandscape = MediaQuery.of(context).orientation == Orientation.landscape;

    return SingleChildScrollView(
      child: Center(
        child: Padding(
          padding: EdgeInsets.all(isLandscape ? 16 : 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.bluetooth,
                size: isLandscape ? 40 : 64,
                color: canConnect
                    ? Theme.of(context).colorScheme.primary
                    : Colors.grey,
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              Text(
                'Last Connected Device',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Text(
                remembered.displayName,
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              SizedBox(height: isLandscape ? 12 : 24),
              ElevatedButton.icon(
                onPressed: canConnect ? () => appState.reconnectToRememberedDevice() : null,
                icon: const Icon(Icons.bluetooth_connected),
                label: Text(canConnect
                    ? 'Reconnect'
                    : appState.maintenanceMode
                        ? 'Maintenance'
                        : appState.isCheckingZone
                            ? 'Checking Zone...'
                            : 'Outside Zone'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: canConnect
                      ? Theme.of(context).colorScheme.primary
                      : Colors.grey,
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.symmetric(
                    horizontal: isLandscape ? 24 : 32,
                    vertical: isLandscape ? 12 : 16,
                  ),
                ),
              ),
              SizedBox(height: isLandscape ? 8 : 16),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextButton.icon(
                    onPressed: () => appState.startScan(),
                    icon: const Icon(Icons.bluetooth_searching, size: 18),
                    label: const Text('Scan'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => appState.clearRememberedDevice(),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Forget'),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.grey,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceListView(BuildContext context, AppStateProvider appState, {bool canConnect = true}) {
    return ListView.builder(
      itemCount: appState.discoveredDevices.length,
      itemBuilder: (context, index) {
        final device = appState.discoveredDevices[index];
        return _DeviceListTile(
          device: device,
          enabled: canConnect,
          onTap: canConnect
              ? () async {
                  await appState.stopScan();
                  await appState.connectToDevice(device);
                }
              : null,
        );
      },
    );
  }

  void _showPathHashWarning(BuildContext context, int hopBytes, String reason) {
    if (reason == 'firmware_unsupported') {
      // Firmware too old to support multi-byte paths
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.warning_amber, size: 24, color: Colors.amber),
              SizedBox(width: 8),
              Flexible(child: Text('Firmware Update Recommended')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your regional admin has enabled $hopBytes-byte path mode for this zone, '
                'but your companion firmware does not support it.',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              const Text(
                'The app will operate in 1-byte mode. Consider updating your companion '
                'firmware to v1.14.0+ for more accurate repeater identification.',
                style: TextStyle(fontSize: 13),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } else {
      // Mode changed successfully
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.linear_scale, size: 24),
              SizedBox(width: 8),
              Flexible(child: Text('Multi-Byte Paths Enabled')),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Your radio has been updated from 1-byte to $hopBytes-byte paths for this session ($reason).',
                style: const TextStyle(fontSize: 14),
              ),
              const SizedBox(height: 12),
              const Text(
                'Your radio will remain in multi-byte mode until you change it.',
                style: TextStyle(fontSize: 13, color: Colors.amber),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }
}

class _DeviceListTile extends StatelessWidget {
  final DiscoveredDevice device;
  final VoidCallback? onTap;
  final bool enabled;

  const _DeviceListTile({
    required this.device,
    this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    // Strip MeshCore- prefix from device name for cleaner display
    final displayName = device.name.replaceFirst('MeshCore-', '');

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: enabled ? null : Colors.grey.shade300,
        child: Icon(
          Icons.bluetooth,
          color: enabled ? null : Colors.grey,
        ),
      ),
      title: Text(
        displayName,
        style: TextStyle(color: enabled ? null : Colors.grey),
      ),
      subtitle: Text(
        device.id,
        style: TextStyle(color: enabled ? null : Colors.grey),
      ),
      trailing: device.rssi != null
          ? _buildRssiChip(device.rssi!, enabled)
          : null,
      enabled: enabled,
      onTap: onTap,
    );
  }

  Widget _buildRssiChip(int rssi, bool enabled) {
    Color color;
    if (!enabled) {
      color = Colors.grey;
    } else if (rssi >= -50) {
      color = Colors.green;
    } else if (rssi >= -70) {
      color = Colors.orange;
    } else {
      color = Colors.red;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.signal_cellular_alt, size: 14, color: color),
          const SizedBox(width: 4),
          Text(
            '$rssi dBm',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}
