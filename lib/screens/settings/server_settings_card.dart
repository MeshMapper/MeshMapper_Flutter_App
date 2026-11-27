import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../services/server_config.dart';
import '../../services/server_settings_store.dart';
import '../../widgets/app_toast.dart';
import 'settings_section_card.dart';

/// Developer Tools: Live or the dev server.
///
/// Live is the default. The dev server is one fixed address (see
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
  }

  bool _differs(ServerSettings stored) =>
      _dev != stored.dev || _keyController.text.trim() != stored.key;

  Future<void> _save(AppStateProvider appState) async {
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final error = await appState.setServer(
        ServerSettings(dev: _dev, key: _keyController.text));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error == null) _seed(appState.serverSettings);
    });
    if (error != null) {
      AppToast.error(context, error);
    } else if (appState.devServerActive) {
      AppToast.warning(context, 'Now using ${appState.serverName}');
    } else if (_dev) {
      AppToast.info(context, 'Saved. Still on Live until the key is entered');
    } else {
      AppToast.success(context, 'Now using the live server');
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

    final active = appState.devServerActive;
    final blocked = appState.serverChangeBlockedReason;
    final dirty = _differs(stored);

    return SettingsSectionCard(title: 'Server', children: [
      ListTile(
        leading: Icon(
          active ? Icons.science : Icons.cloud_done,
          color: active ? Colors.deepOrange : Colors.green,
        ),
        title: Text(active ? 'Dev server' : 'Live server'),
        subtitle: Text(appState.serverName),
      ),
      SwitchListTile(
        secondary: const Icon(Icons.dns),
        title: const Text('Use dev server'),
        subtitle: const Text('${ServerConfig.devDomain}. Needs its own API '
            'key'),
        value: _dev,
        onChanged: _busy
            ? null
            : (value) => setState(() {
                  _dev = value;
                  _testResult = null;
                }),
      ),
      if (_dev) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            controller: _keyController,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'Dev API key',
              helperText: 'The dev server\'s app key. Stored on this device',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() => _testResult = null),
          ),
        ),
        if (_testResult != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
            child: Text(_testResult!, style: const TextStyle(fontSize: 13)),
          ),
      ],
      if (blocked != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.lock, size: 16, color: Colors.amber),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  blocked,
                  style: const TextStyle(fontSize: 12, color: Colors.amber),
                ),
              ),
            ],
          ),
        ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Row(
          children: [
            if (_dev)
              OutlinedButton(
                onPressed: _busy ? null : () => _test(appState),
                child: const Text('Test'),
              ),
            const Spacer(),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(right: 12),
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            FilledButton(
              onPressed: _busy || !dirty ? null : () => _save(appState),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ]);
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
