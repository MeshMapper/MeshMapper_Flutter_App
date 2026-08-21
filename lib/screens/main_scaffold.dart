import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../models/connection_state.dart';
import '../providers/app_state_provider.dart';
import '../services/permission_disclosure_service.dart';
import '../services/portal_account_service.dart';
import '../utils/debug_logger_io.dart';
import '../widgets/app_toast.dart';
import 'home_screen.dart';
import 'log_screen.dart';
import 'connection_screen.dart';
import 'settings_screen.dart';
import 'graph_screen.dart';

/// Main scaffold with bottom navigation
class MainScaffold extends StatefulWidget {
  const MainScaffold({super.key});

  @override
  State<MainScaffold> createState() => _MainScaffoldState();
}

class _MainScaffoldState extends State<MainScaffold> {
  int _selectedIndex = 0;
  bool _hasCheckedDisclosure = false;
  bool _hasShownLocationSettingsPrompt = false;
  bool _floodDisabledDialogOpen = false;
  bool _linkPromptDialogOpen = false;

  final List<Widget> _screens = [
    const HomeScreen(),
    const LogScreen(),
    const GraphScreen(),
    const ConnectionScreen(),
    const SettingsScreen(),
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
    if (_hasCheckedDisclosure) return;
    _hasCheckedDisclosure = true;

    if (kIsWeb) {
      // Web: No disclosure dialog needed, just request permission
      // This triggers the browser's native location permission prompt
      debugLog(
          '[DISCLOSURE] Web platform - requesting GPS permission directly');
      await _requestWebGpsPermission();
      return;
    }

    // Check if disclosure was already shown
    final hasShown = await PermissionDisclosureService.hasShownDisclosure();
    if (!hasShown) {
      // Show the disclosure dialog
      if (!mounted) return;
      debugLog('[DISCLOSURE] Showing location disclosure dialog');
      await PermissionDisclosureService.showLocationDisclosure(context);
    }

    debugLog('[DISCLOSURE] Ensuring location permission after disclosure');
    await _ensureLocationPermission();
  }

  /// Request GPS permission on web (triggers browser's native prompt)
  Future<void> _requestWebGpsPermission() async {
    LocationPermission permission = await Geolocator.checkPermission();
    debugLog('[DISCLOSURE] Web GPS permission check: $permission');

    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      debugLog('[DISCLOSURE] Web GPS permission after request: $permission');
    }

    final granted = permission == LocationPermission.always ||
        permission == LocationPermission.whileInUse;

    if (granted && mounted) {
      debugLog('[DISCLOSURE] Web GPS permission granted, starting GPS service');
      final appState = context.read<AppStateProvider>();
      await appState.restartGpsAfterPermission();
    }
  }

  /// Ensure location permission after disclosure has been shown.
  /// Requests when possible, restarts GPS when granted, and surfaces a settings CTA
  /// when the permission has been permanently denied.
  Future<void> _ensureLocationPermission() async {
    bool granted = false;

    if (Platform.isIOS) {
      // iOS: Request location via Geolocator
      LocationPermission permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      debugLog('[DISCLOSURE] iOS location permission: $permission');
      if (permission == LocationPermission.deniedForever) {
        _showLocationSettingsPrompt();
        return;
      }
      granted = permission == LocationPermission.always ||
          permission == LocationPermission.whileInUse;
    } else {
      // Android: only request if needed so previously granted permission just restarts GPS.
      var status = await Permission.locationWhenInUse.status;
      if (status.isDenied) {
        status = await Permission.locationWhenInUse.request();
      }
      debugLog('[DISCLOSURE] Android location permission: $status');
      if (status.isPermanentlyDenied) {
        _showLocationSettingsPrompt();
        return;
      }
      granted = status.isGranted;
    }

    // If permission was granted, restart GPS service (it skipped starting earlier)
    if (granted && mounted) {
      debugLog('[DISCLOSURE] Permission granted, starting GPS service');
      final appState = context.read<AppStateProvider>();
      await appState.restartGpsAfterPermission();
    }
  }

  Future<void> _showFloodDisabledDialog() async {
    final appState = context.read<AppStateProvider>();
    debugLog('[APP] Showing flood-traffic-disabled-by-region alert');
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Flood Traffic Unavailable'),
        content: const Text(
          'Your regional MeshMapper admin has disabled flood traffic in this '
          'area, so Active and Hybrid modes have been turned off for this '
          'session. Passive Mode and Trace Mode remain available. Please '
          'reach out to your regional admin if you have questions.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    appState.clearFloodDisabledAlert();
    _floodDisabledDialogOpen = false;
  }

  /// One-tap offer to bind the connected radio to the signed-in account.
  ///
  /// Mirrors the flood-disabled alert: a postFrameCallback plus a local
  /// open-guard, because build() runs on every provider notify.
  Future<void> _showLinkPrompt() async {
    final appState = context.read<AppStateProvider>();
    final deviceName = appState.portalLinkPromptDeviceName ?? 'this device';
    final accountName = appState.portalAccount?.displayName ?? 'your account';
    debugLog('[ACCOUNT] Showing the device link prompt');

    final accepted = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Link This Device?'),
        content: Text(
          "Link '$deviceName' to your MeshMapper account ($accountName)? "
          'Wardriving data from this device will count toward your account.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('No thanks'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Link Device'),
          ),
        ],
      ),
    );

    final outcome = await appState.respondToLinkPrompt(accepted ?? false);
    _linkPromptDialogOpen = false;
    if (!mounted) return;
    await showLinkOutcome(context, outcome);
  }

  /// Present a link result. Success is a toast; the two cases that need the
  /// user to go somewhere else get a dialog. Every other outcome — network,
  /// server, unsupported firmware, unauthorized — is deliberately SILENT:
  /// linking must never look like a wardriving failure.
  static Future<void> showLinkOutcome(
      BuildContext context, PortalLinkOutcome outcome) async {
    switch (outcome.status) {
      case PortalLinkStatus.linked:
        AppToast.success(
          context,
          'Linked to ${outcome.accountName ?? 'your MeshMapper account'}',
        );
      case PortalLinkStatus.adoptionRequired:
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Finish Setup in the Portal'),
            content: Text(
              'Your account still has ${outcome.adoptionDeviceCount} '
              'placeholder device(s). Claiming them moves every one of your '
              'radios at once, so it has to be done deliberately at '
              'portal.meshmapper.net. Once that is finished, come back and '
              'link this device.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      case PortalLinkStatus.alreadyLinkedOtherAccount:
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Already Linked Elsewhere'),
            content: const Text(
              'This radio is already linked to a different MeshMapper '
              'account. Unlink it there first, then link it here.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      case PortalLinkStatus.skipped:
      case PortalLinkStatus.unauthorized:
      case PortalLinkStatus.failed:
        break;
    }
  }

  void _showLocationSettingsPrompt() {
    if (!mounted || _hasShownLocationSettingsPrompt) return;
    _hasShownLocationSettingsPrompt = true;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Location permission is disabled in system settings.'),
        action: SnackBarAction(
          label: 'Settings',
          onPressed: Geolocator.openAppSettings,
        ),
      ),
    );
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

    // Listen for flood-traffic-disabled-by-region alert (user had it on,
    // region forced it off on auth/zone-change)
    if (appState.floodDisabledAlertPending && !_floodDisabledDialogOpen) {
      _floodDisabledDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showFloodDisabledDialog();
      });
    }

    // MyMeshMapper account link offer (post-connection, non-fatal).
    // A pending prompt survives disconnect by design (the provider no-ops
    // safely if it is answered afterwards), but never RAISE the dialog for a
    // dead connection — the link handshake needs the radio to sign a nonce.
    if (appState.isConnected &&
        appState.portalLinkPromptPending &&
        !_linkPromptDialogOpen) {
      _linkPromptDialogOpen = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _showLinkPrompt();
      });
    }

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;

    return Scaffold(
      body: Stack(
        children: [
          IndexedStack(
            index: _selectedIndex,
            children: _screens,
          ),
          if (appState.isAnonymousReconnectInProgress)
            Positioned.fill(
              child: Container(
                color: Colors.black54,
                child: Center(
                  child: _buildAnonymousReconnectOverlay(appState),
                ),
              ),
            ),
        ],
      ),
      bottomNavigationBar: isLandscape
          ? _buildCompactNavBar(appState)
          : _buildStandardNavBar(appState),
    );
  }

  Widget _buildAnonymousReconnectOverlay(AppStateProvider appState) {
    final enabling = appState.anonymousReconnectEnabling;
    final step = appState.connectionStep;
    final totalSteps = ConnectionStepExtension.totalSteps;
    final progress = step.stepNumber > 0 ? step.stepNumber / totalSteps : 0.0;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
        decoration: BoxDecoration(
          color: const Color(0xFF1E293B),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              color: Colors.orange.shade400,
            ),
            const SizedBox(height: 20),
            Text(
              enabling
                  ? 'Enabling Anonymous Mode...'
                  : 'Disabling Anonymous Mode...',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.grey.shade100,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: progress,
                backgroundColor: Colors.grey.shade800,
                color: Colors.orange.shade400,
                minHeight: 4,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              step.description,
              style: TextStyle(
                color: Colors.grey.shade400,
                fontSize: 13,
              ),
            ),
            if (step.stepNumber > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'Step ${step.stepNumber} of $totalSteps',
                  style: TextStyle(
                    color: Colors.grey.shade600,
                    fontSize: 12,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Compact navigation bar for landscape mode (icon-only, shorter height)
  Widget _buildCompactNavBar(AppStateProvider appState) {
    // Pad for the system navigation/gesture bar so the icons aren't hidden
    // behind it in landscape; the surface background fills the inset area (#224).
    return Container(
      padding:
          EdgeInsets.only(bottom: MediaQuery.of(context).viewPadding.bottom),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border(
          top: BorderSide(
            color: Theme.of(context).colorScheme.outlineVariant,
            width: 0.5,
          ),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: [
          _buildCompactNavItem(
            icon: Icons.map_outlined,
            activeIcon: Icons.map,
            index: 0,
          ),
          _buildCompactNavItem(
            icon: Icons.list_alt_outlined,
            activeIcon: Icons.list_alt,
            index: 1,
            showBadge: appState.errorLogEntries.isNotEmpty,
          ),
          _buildCompactNavItem(
            icon: Icons.history_outlined,
            activeIcon: Icons.history,
            index: 2,
          ),
          _buildCompactNavItem(
            icon: appState.isConnected
                ? Icons.bluetooth_connected
                : Icons.bluetooth,
            activeIcon: appState.isConnected
                ? Icons.bluetooth_connected
                : Icons.bluetooth,
            index: 3,
            color: appState.isConnected ? Colors.green : null,
          ),
          _buildCompactNavItem(
            icon: Icons.settings_outlined,
            activeIcon: Icons.settings,
            index: 4,
          ),
        ],
      ),
    );
  }

  Widget _buildCompactNavItem({
    required IconData icon,
    required IconData activeIcon,
    required int index,
    bool showBadge = false,
    Color? color,
  }) {
    final isSelected = _selectedIndex == index;
    final effectiveColor = color ??
        (isSelected
            ? Theme.of(context).colorScheme.primary
            : Theme.of(context).colorScheme.onSurfaceVariant);

    return GestureDetector(
      onTap: () => setState(() => _selectedIndex = index),
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        height: 56,
        child: Center(
          child: Badge(
            isLabelVisible: showBadge,
            child: Icon(
              isSelected ? activeIcon : icon,
              size: 24,
              color: effectiveColor,
            ),
          ),
        ),
      ),
    );
  }

  /// Standard navigation bar for portrait mode
  Widget _buildStandardNavBar(AppStateProvider appState) {
    return BottomNavigationBar(
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
        const BottomNavigationBarItem(
          icon: Icon(Icons.history_outlined),
          activeIcon: Icon(Icons.history),
          label: 'History',
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
    );
  }
}
