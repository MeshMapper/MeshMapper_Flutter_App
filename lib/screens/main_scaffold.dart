import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
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

  final List<Widget> _screens = [
    HomeScreen(),
    LogScreen(),
    ConnectionScreen(),
    SettingsScreen(),
  ];

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
