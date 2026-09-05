import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../services/portal_account_service.dart';
import '../../utils/debug_logger_io.dart';
import '../../widgets/app_toast.dart';
import 'settings_section_card.dart';

/// Settings folder: MeshMapper Account.
class AccountSettingsPage extends StatelessWidget {
  const AccountSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final isAutoMode = appState.autoPingEnabled;

    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('MeshMapper Account', style: TextStyle(fontSize: 18)),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
        children: [
          if (isAutoMode) const AutoPingLockBanner(),
          SettingsSectionCard(title: 'Account', children: [
            if (!appState.isPortalLoggedIn)
              ListTile(
                leading: const Icon(Icons.account_circle_outlined),
                title: const Text('Sign in to MyMeshMapper'),
                subtitle: const Text(
                    'Link your radios so wardriving counts toward your account'),
                trailing: const Icon(Icons.open_in_new, size: 18),
                onTap: () => _startPortalSignIn(context, appState),
              )
            else ...[
              ListTile(
                leading: const Icon(Icons.account_circle, color: Colors.green),
                title: Text(appState.portalAccount?.displayName ?? 'Signed in'),
                subtitle: Text('@${appState.portalAccount?.username ?? ''}'),
              ),
              ListTile(
                leading: const Icon(Icons.logout, color: Colors.orange),
                title: const Text('Sign Out'),
                subtitle: const Text('Keeps your linked devices on the server'),
                onTap: () => _showPortalSignOutConfirmation(context, appState),
              ),
            ],
          ]),
          if (appState.isPortalLoggedIn)
            SettingsSectionCard(title: 'Devices', children: [
              ListTile(
                leading: Icon(
                  appState.isCurrentDeviceLinked ? Icons.link : Icons.link_off,
                  color: appState.isCurrentDeviceLinked
                      ? Colors.green
                      : Colors.grey,
                ),
                title: const Text('This Device'),
                subtitle: Text(
                  !appState.isConnected
                      ? 'Connect a device to link it'
                      : appState.isCurrentDeviceLinked
                          ? 'Linked to your account'
                          : 'Not linked',
                ),
                trailing: !appState.isConnected
                    ? null
                    : appState.isCurrentDeviceLinked
                        ? TextButton(
                            onPressed: isAutoMode
                                ? null
                                : () => _unlinkPortalDevice(context, appState),
                            child: const Text('Unlink'),
                          )
                        : TextButton(
                            // Linking drives the radio (CMD_SIGN), so it
                            // follows this screen's auto-ping lock.
                            onPressed: isAutoMode
                                ? null
                                : () => _linkPortalDevice(context, appState),
                            child: const Text('Link now'),
                          ),
              ),
              ListTile(
                leading: const Icon(Icons.devices_other),
                title: const Text('Linked Devices'),
                subtitle: Text(
                    '${appState.portalLinkedDeviceCount} device(s) on this account'),
                trailing: const Icon(Icons.refresh),
                onTap: () => _refreshPortalAccount(context, appState),
              ),
              if (appState.hasPortalLinkResets)
                ListTile(
                  leading: const Icon(Icons.replay),
                  title: const Text('Re-enable Link Prompts'),
                  subtitle: const Text('Ask again for declined or unsupported '
                      'devices'),
                  onTap: () => _resetPortalDeclines(context, appState),
                ),
            ]),
        ],
      ),
    );
  }

  Future<void> _startPortalSignIn(
      BuildContext context, AppStateProvider appState) async {
    debugLog('[ACCOUNT] Opening the portal sign-in page');
    final launched = await appState.beginPortalSignIn();
    if (!context.mounted) return;
    if (launched) {
      AppToast.info(context, 'Finish signing in, then return to the app');
    } else {
      AppToast.error(context, 'Could not open the browser');
    }
  }

  Future<void> _linkPortalDevice(
      BuildContext context, AppStateProvider appState) async {
    AppToast.info(context, 'Linking this device...');
    final outcome = await appState.startManualDeviceLink();
    if (!context.mounted) return;
    switch (outcome.status) {
      case PortalLinkStatus.linked:
        AppToast.success(context,
            'Linked to ${outcome.accountName ?? 'your MeshMapper account'}');
      case PortalLinkStatus.adoptionRequired:
        AppToast.warning(
          context,
          'Claim your ${outcome.adoptionDeviceCount} placeholder device(s) at '
          'portal.meshmapper.net first',
          duration: const Duration(seconds: 6),
        );
      case PortalLinkStatus.alreadyLinkedOtherAccount:
        AppToast.error(context, 'This radio is linked to a different account');
      case PortalLinkStatus.unauthorized:
        AppToast.error(context, 'Signed out — please sign in again');
      case PortalLinkStatus.skipped:
      case PortalLinkStatus.failed:
        // A manual tap deserves feedback even though the automatic path is
        // deliberately silent. When the portal named a wait, say it: retrying
        // inside the block only re-arms a fresh penalty.
        final wait = outcome.retryAfter;
        if (wait != null) {
          AppToast.warning(
              context, 'Too many attempts. Try again in ${_waitLabel(wait)}.');
        } else {
          AppToast.error(context, 'Could not link right now — try again later');
        }
    }
  }

  /// Round a backoff up to a whole unit the user can act on.
  String _waitLabel(Duration wait) {
    if (wait.inSeconds < 60) return '${wait.inSeconds}s';
    return '${(wait.inSeconds / 60).ceil()} min';
  }

  Future<void> _unlinkPortalDevice(
      BuildContext context, AppStateProvider appState) async {
    final ok = await appState.unlinkCurrentDevice();
    if (!context.mounted) return;
    if (ok) {
      AppToast.success(context, 'Device unlinked');
    } else {
      AppToast.error(context, 'Could not unlink right now');
    }
  }

  Future<void> _refreshPortalAccount(
      BuildContext context, AppStateProvider appState) async {
    await appState.refreshPortalAccount(force: true);
    if (!context.mounted) return;
    // A rate-limited refresh makes no request, so the count below would be the
    // same stale number every tap, which reads as a dead button and invites
    // more tapping. Every tap during a block extends it server-side.
    final backoff = appState.portalRefreshBackoff;
    if (backoff != null) {
      AppToast.error(context,
          'Too many refreshes. Try again in ${_formatBackoff(backoff)}.');
      return;
    }
    AppToast.simple(
        context, '${appState.portalLinkedDeviceCount} linked device(s)');
  }

  /// Rounded up: telling someone to wait "0 minutes" is worse than telling
  /// them to wait a beat longer than they have to.
  String _formatBackoff(Duration backoff) {
    if (backoff.inSeconds < 60) return '${backoff.inSeconds + 1} seconds';
    final minutes = (backoff.inSeconds / 60).ceil();
    return minutes == 1 ? '1 minute' : '$minutes minutes';
  }

  Future<void> _resetPortalDeclines(
      BuildContext context, AppStateProvider appState) async {
    await appState.resetLinkPromptDeclines();
    if (!context.mounted) return;
    AppToast.success(context, 'Link prompts re-enabled');
  }

  void _showPortalSignOutConfirmation(
      BuildContext context, AppStateProvider appState) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sign Out'),
        content: const Text(
          'Sign out of MyMeshMapper on this phone? Your radios stay linked to '
          'your account, and wardriving keeps working.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(dialogContext);
              appState.portalSignOut();
            },
            style: TextButton.styleFrom(foregroundColor: Colors.orange),
            child: const Text('Sign Out'),
          ),
        ],
      ),
    );
  }
}
