import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../services/permission_disclosure_service.dart';
import '../utils/debug_logger_io.dart';
import 'home_screen.dart';
import 'log_screen.dart';
import 'connection_screen.dart';
import 'settings_screen.dart';

/// Main scaffold with bottom navigation
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _selectedIndex = 0;
  bool _hasCheckedDisclosure = false;

  final List<Widget> _screens = [
    HomeScreen(),
    LogScreen(),
    ConnectionScreen(),
    SettingsScreen(),
  ];

  @override
  void initState() {
    super.initState();
    // Check disclosure after first frame (needs context)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkAndShowDisclosure();
    });
  }

  /// Check if location disclosure has been shown, show it if not, then request permissions
  Future<void> _checkAndShowDisclosure() async {
    if (_hasCheckedDisclosure || kIsWeb) return;
    _hasCheckedDisclosure = true;

    // Check if disclosure was already shown
    final hasShown = await PermissionDisclosureService.hasShownDisclosure();
    if (hasShown) {
      debugLog('[DISCLOSURE] Already shown, skipping');
      return;
    }

    // Show the disclosure dialog
    if (!mounted) return;
    debugLog('[DISCLOSURE] Showing location disclosure dialog');
    final accepted = await PermissionDisclosureService.showLocationDisclosure(context);

    if (accepted) {
      debugLog('[DISCLOSURE] User accepted, requesting permissions');
      await _requestPermissionsAfterDisclosure();
    } else {
      debugLog('[DISCLOSURE] User declined location access');
    }
  }

  /// Request permissions after user accepts disclosure
  Future<void> _requestPermissionsAfterDisclosure() async {
    bool granted = false;

    if (Platform.isIOS) {
      // iOS: Request location via Geolocator
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      debugLog('[DISCLOSURE] iOS location permission: $permission');
      granted = permission == LocationPermission.always ||
                permission == LocationPermission.whileInUse;
    } else {
      // Android: Request location via permission_handler
      final status = await Permission.locationWhenInUse.request();
      debugLog('[DISCLOSURE] Android location permission: $status');
      granted = status.isGranted;
    }

    // If permission was granted, restart GPS service (it skipped starting earlier)
    if (granted && mounted) {
      debugLog('[DISCLOSURE] Permission granted, starting GPS service');
      final appState = context.read<AppStateProvider>();
      await appState.restartGpsAfterPermission();
    }
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();

    // Listen for map navigation requests from log screen
    if (appState.requestMapTabSwitch && _selectedIndex != 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _selectedIndex = 0; // Switch to map tab
          });
          appState.clearMapTabSwitchRequest();
        }
      });
    }

    // Listen for error log requests - switch to Log tab
    if (appState.requestErrorLogSwitch && _selectedIndex != 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _selectedIndex = 1; // Switch to Log tab
          });
          // Don't clear yet - LogScreen needs to see it to switch to Error tab
        }
      });
    }

    return Scaffold(
      body: IndexedStack(
        index: _selectedIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _selectedIndex,
        onTap: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        backgroundColor: Theme.of(context).colorScheme.surface,
        selectedItemColor: Theme.of(context).colorScheme.primary,
        unselectedItemColor: Theme.of(context).colorScheme.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
        selectedFontSize: 11,
        unselectedFontSize: 11,
        iconSize: 22,
        items: [
          const BottomNavigationBarItem(
            icon: Icon(Icons.map_outlined),
            activeIcon: Icon(Icons.map),
            label: 'Map',
          ),
          BottomNavigationBarItem(
            icon: Badge(
              isLabelVisible: appState.errorLogEntries.isNotEmpty,
              child: const Icon(Icons.list_alt_outlined),
            ),
            activeIcon: Badge(
              isLabelVisible: appState.errorLogEntries.isNotEmpty,
              child: const Icon(Icons.list_alt),
            ),
            label: 'Log',
          ),
          BottomNavigationBarItem(
            icon: Icon(
              appState.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
              color: appState.isConnected ? Colors.green : null,
            ),
            activeIcon: Icon(
              appState.isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
              color: appState.isConnected ? Colors.green : null,
            ),
            label: appState.isConnected ? 'Connected' : 'Connect',
          ),
          const BottomNavigationBarItem(
            icon: Icon(Icons.settings_outlined),
            activeIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
