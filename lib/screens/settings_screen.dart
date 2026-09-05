import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/app_state_provider.dart';
import '../utils/constants.dart';
import 'settings/about_settings_page.dart';
import 'settings/account_settings_page.dart';
import 'settings/api_endpoints_settings_page.dart';
import 'settings/data_settings_page.dart';
import 'settings/developer_settings_page.dart';
import 'settings/general_settings_page.dart';
import 'settings/map_settings_page.dart';
import 'settings/pinging_settings_page.dart';
import 'settings/settings_section_card.dart';
import 'watch_diagnostics_screen.dart';

/// Settings tab: one row per settings folder, each opening its own page.
///
/// The folder pages live in `settings/`. This screen only decides which rows
/// to show; every tile, dialog and platform gate lives on the page it belongs
/// to.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final isAutoMode = appState.autoPingEnabled;

    final accountSubtitle = appState.isPortalLoggedIn
        ? (appState.portalAccount?.displayName ?? 'Signed in')
        : 'Sign in to link your radios';
    final aboutSubtitle = kIsWeb
        ? 'Version ${AppConstants.appVersion}, feedback'
        : 'Version ${AppConstants.appVersion}, feedback, debug logs';

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Settings', style: TextStyle(fontSize: 18)),
        automaticallyImplyLeading: false,
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          if (isAutoMode) const AutoPingLockBanner(),
          SettingsSectionCard(children: [
            _FolderTile(
              icon: Icons.tune,
              title: 'General',
              subtitle: 'Theme, units, sounds, background location',
              builder: (_) => const GeneralSettingsPage(),
            ),
            _FolderTile(
              icon: Icons.map_outlined,
              title: 'Map',
              subtitle: 'Offline maps, coverage overlay, markers',
              builder: (_) => const MapSettingsPage(),
            ),
            _FolderTile(
              icon: Icons.cell_tower,
              title: 'Pinging',
              subtitle: 'Intervals, smart pinging, modes, filters, radio',
              builder: (_) => const PingingSettingsPage(),
            ),
            _FolderTile(
              icon: Icons.storage,
              title: 'Data',
              subtitle: 'Queued pings, map markers, offline sessions',
              builder: (_) => const DataSettingsPage(),
            ),
            // MeshMapper Account is mobile only. The sign-in flow needs an
            // OS-registered URL scheme, which the web build cannot have.
            if (!kIsWeb)
              _FolderTile(
                icon: Icons.account_circle_outlined,
                title: 'MeshMapper Account',
                subtitle: accountSubtitle,
                builder: (_) => const AccountSettingsPage(),
              ),
            _FolderTile(
              icon: Icons.cloud_outlined,
              title: 'API Endpoints',
              subtitle: 'MeshMapper and custom endpoints',
              builder: (_) => const ApiEndpointsSettingsPage(),
            ),
            // Visibility is one-way on purpose: after an unpair the row
            // stays reachable, because that failure is when it is most useful.
            if (appState.shouldShowWatchDiagnostics)
              _FolderTile(
                icon: Icons.watch_outlined,
                title: 'Apple Watch',
                subtitle: 'Inspect pairing and delivery state',
                builder: (_) =>
                    WatchDiagnosticsScreen(bridge: appState.watchBridge),
              ),
          ]),
          SettingsSectionCard(children: [
            _FolderTile(
              icon: Icons.info_outline,
              title: 'About & Support',
              subtitle: aboutSubtitle,
              builder: (_) => const AboutSettingsPage(),
            ),
            // Unlocked by tapping the version seven times on About & Support.
            if (appState.developerModeEnabled)
              _FolderTile(
                icon: Icons.developer_mode,
                title: 'Developer Tools',
                subtitle: 'GPS simulator',
                builder: (_) => const DeveloperSettingsPage(),
              ),
          ]),
        ],
      ),
    );
  }
}

/// One row on the Settings tab that opens a folder page.
class _FolderTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final WidgetBuilder builder;

  const _FolderTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.builder,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: builder),
      ),
    );
  }
}
