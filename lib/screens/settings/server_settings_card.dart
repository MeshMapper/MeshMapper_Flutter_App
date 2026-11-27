import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../services/server_config.dart';
import '../../services/server_settings_store.dart';
import '../../widgets/app_toast.dart';
import 'settings_section_card.dart';

/// Developer Tools: which of the two servers the app is on, Prod or Dev.
///
/// Prod (the live server) is the default. The dev server is one fixed address (see
/// [ServerConfig]); the app cannot be pointed anywhere else. It needs the
/// dev server's own app key and is only active once the switch is on, the
/// key is entered and both are saved. A change of server is refused while a
/// session is active or anything is waiting to upload.
class ServerSettingsCard extends StatefulWidget {
  const ServerSettingsCard({super.key});

  @override
  State<ServerSettingsCard> createState() => _ServerSettingsCardState();
}

class _ServerSettingsCardState extends State<ServerSettingsCard> {
  final _keyController = TextEditingController();
  bool _dev = false;
  ServerSettings? _seededFrom;
  bool _busy = false;
  String? _testResult;

  @override
  void dispose() {
    _keyController.dispose();
    super.dispose();
  }

  void _seed(ServerSettings stored) {
    _dev = stored.dev;
    _keyController.text = stored.key;
    _seededFrom = stored;
    _testResult = null;
  }

  String get _typedKey => _keyController.text.trim();

  void _select(bool dev) => setState(() {
        _dev = dev;
        _testResult = null;
      });

  Future<void> _save(AppStateProvider appState) async {
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final error = await appState
        .setServer(ServerSettings(dev: _dev, key: _keyController.text));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error == null) _seed(appState.serverSettings);
    });
    if (error != null) {
      AppToast.error(context, error);
    } else if (appState.devServerActive) {
      AppToast.warning(context, 'Now on Dev (${appState.serverName})');
    } else {
      AppToast.success(context, 'Now on Prod (${appState.serverName})');
    }
  }

  Future<void> _test(AppStateProvider appState) async {
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _testResult = null;
    });
    final result = await appState.testServer(key: _keyController.text);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _testResult = result;
    });
  }

  @override
  Widget build(BuildContext context) {
    final appState = context.watch<AppStateProvider>();
    final stored = appState.serverSettings;
    // Seeded from what is stored, and again whenever THAT changes (a save,
    // the load at launch, developer mode going off). Typing never changes
    // what is stored, so it is never overwritten.
    if (!identical(stored, _seededFrom)) _seed(stored);

    final devActive = appState.devServerActive;
    final blocked = appState.serverChangeBlockedReason;
    final switching = _dev != devActive;
    final keyChanged = _dev && _typedKey != stored.key;
    final canSave = !_busy && (!_dev || _typedKey.isNotEmpty);

    return SettingsSectionCard(title: 'Server', children: [
      _ServerOption(
        icon: Icons.cloud_done,
        color: Colors.green,
        title: 'Prod',
        host: ServerConfig.liveDomain,
        selected: !_dev,
        active: !devActive,
        onTap: _busy ? null : () => _select(false),
      ),
      _ServerOption(
        icon: Icons.science,
        color: Colors.deepOrange,
        title: 'Dev',
        host: ServerConfig.devDomain,
        selected: _dev,
        active: devActive,
        onTap: _busy ? null : () => _select(true),
      ),
      if (_dev)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            controller: _keyController,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: InputDecoration(
              labelText: 'Dev API key',
              helperText: 'Needed to use Dev. Stored on this device',
              border: const OutlineInputBorder(),
              isDense: true,
              suffixIcon: TextButton(
                onPressed: _busy || _typedKey.isEmpty
                    ? null
                    : () => _test(appState),
                child: const Text('Test'),
              ),
            ),
            onChanged: (_) => setState(() => _testResult = null),
          ),
        ),
      if (_dev && _testResult != null)
        _Note(
          icon: _testResult!.startsWith('Working')
              ? Icons.check_circle
              : Icons.error_outline,
          color: _testResult!.startsWith('Working')
              ? Colors.green
              : Colors.orange,
          text: _testResult!,
        ),
      if (blocked != null && switching)
        _Note(icon: Icons.lock, color: Colors.amber, text: blocked),
      if (switching || keyChanged)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: canSave ? () => _save(appState) : null,
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(!switching
                      ? 'Save key'
                      : (_dev ? 'Switch to Dev' : 'Switch to Prod')),
            ),
          ),
        )
      else
        const SizedBox(height: 4),
    ]);
  }
}

/// One of the two servers, as a row that can be picked. The server the app
/// is on right now carries an "IN USE" tag, which only moves after a save.
class _ServerOption extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String host;
  final bool selected;
  final bool active;
  final VoidCallback? onTap;

  const _ServerOption({
    required this.icon,
    required this.color,
    required this.title,
    required this.host,
    required this.selected,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(icon, color: selected || active ? color : null),
      title: Row(
        children: [
          Text(title),
          if (active) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text(
                'IN USE',
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
      subtitle: Text(host),
      trailing: Icon(
        selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
        color: selected ? scheme.primary : null,
      ),
      onTap: onTap,
    );
  }
}

/// A short line under the options: a test result or why a switch is refused.
class _Note extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String text;

  const _Note({required this.icon, required this.color, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(fontSize: 12, color: color)),
          ),
        ],
      ),
    );
  }
}

/// Shown at the top of the map for as long as the dev server is active, so
/// a real drive is never recorded on the dev server by accident. It has no
/// close button and cannot be dismissed: it goes when the app is back on
/// Live.
class DevServerBanner extends StatelessWidget {
  final String serverName;

  const DevServerBanner({super.key, required this.serverName});

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).padding;
    return Semantics(
      liveRegion: true,
      label: 'Dev server $serverName. Nothing recorded now goes to the '
          'live map.',
      child: Container(
        width: double.infinity,
        color: Colors.deepOrange,
        padding: EdgeInsets.fromLTRB(inset.left + 12, 5, inset.right + 12, 5),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.science, size: 16, color: Colors.white),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                'DEV SERVER  $serverName',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
