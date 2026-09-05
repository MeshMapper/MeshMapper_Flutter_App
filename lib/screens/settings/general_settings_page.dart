import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:geolocator/geolocator.dart';

import '../../providers/app_state_provider.dart';
import '../../services/permission_disclosure_service.dart';
import 'settings_section_card.dart';

/// Settings folder: General.
class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final prefs = appState.preferences;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('General', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          SettingsSectionCard(children: [
            SwitchListTile(
              secondary: Icon(
                prefs.themeMode == 'dark' ? Icons.dark_mode : Icons.light_mode,
              ),
              title: const Text('Theme'),
              subtitle:
                  Text(prefs.themeMode == 'dark' ? 'Dark mode' : 'Light mode'),
              value: prefs.themeMode == 'dark',
              onChanged: (isDark) {
                appState.setThemeMode(isDark ? 'dark' : 'light');
              },
            ),
            if (!kIsWeb) _BackgroundModeToggle(appState: appState),
            SwitchListTile(
              secondary: Icon(
                prefs.isImperial ? Icons.square_foot : Icons.straighten,
              ),
              title: const Text('Units'),
              subtitle: Text(
                  prefs.isImperial ? 'Imperial (mi, ft)' : 'Metric (km, m)'),
              value: prefs.isImperial,
              onChanged: (isImperial) {
                appState.setUnitSystem(isImperial ? 'imperial' : 'metric');
              },
            ),
            SwitchListTile(
              secondary: Icon(
                  appState.isSoundEnabled ? Icons.volume_up : Icons.volume_off),
              title: const Text('Sound Notifications'),
              subtitle: Text(
                  appState.isSoundEnabled ? 'Plays on ping events' : 'Silent'),
              value: appState.isSoundEnabled,
              onChanged: (_) => appState.toggleSoundEnabled(),
            ),
            if (appState.isSoundEnabled) ...[
              SwitchListTile(
                secondary: const SizedBox(width: 24),
                title: const Text('Ping Sent'),
                subtitle: const Text('Sound when TX ping or discovery is sent'),
                value: appState.isTxSoundEnabled,
                onChanged: (value) => appState.setTxSoundEnabled(value),
              ),
              SwitchListTile(
                secondary: const SizedBox(width: 24),
                title: const Text('Response Received'),
                subtitle:
                    const Text('Sound when repeater echo or RX is received'),
                value: appState.isRxSoundEnabled,
                onChanged: (value) => appState.setRxSoundEnabled(value),
              ),
              SwitchListTile(
                secondary: const SizedBox(width: 24),
                title: const Text('Disconnect Alert'),
                subtitle:
                    const Text('Triple beep when pinging stops unexpectedly'),
                value: appState.isDisconnectAlertEnabled,
                onChanged: (value) => appState.setDisconnectAlertEnabled(value),
              ),
            ],
          ]),

          // Exit Options (Android only)
          if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android)
            SettingsSectionCard(title: 'Exit', children: [
              SwitchListTile(
                secondary: const Icon(Icons.exit_to_app),
                title: const Text('Close App After Disconnect'),
                subtitle:
                    const Text('Automatically exit the app when disconnecting'),
                value: prefs.closeAppAfterDisconnect,
                onChanged: (value) =>
                    appState.setCloseAppAfterDisconnect(value),
              ),
              ListTile(
                leading:
                    const Icon(Icons.power_settings_new, color: Colors.red),
                title: const Text('Close App'),
                subtitle: const Text('Exit the app completely'),
                onTap: () => _showCloseAppConfirmation(context, appState),
              ),
            ]),
        ],
      ),
    );
  }

  void _showCloseAppConfirmation(
      BuildContext context, AppStateProvider appState) {
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
    final accepted =
        await PermissionDisclosureService.showBackgroundLocationDisclosure(
            context);
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
      title: const Text('Background Location'),
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
