import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../services/server_config.dart';
import '../../services/server_settings_store.dart';
import '../../widgets/app_toast.dart';
import 'settings_section_card.dart';

/// Developer Tools: which server the app talks to.
///
/// Live is the default. Custom takes a server URL and that server's app key
/// and is only active once both are filled and saved. A change of server is
/// refused while a session is active or anything is waiting to upload.
class ServerSettingsCard extends StatefulWidget {
  const ServerSettingsCard({super.key});

  @override
  State<ServerSettingsCard> createState() => _ServerSettingsCardState();
}

class _ServerSettingsCardState extends State<ServerSettingsCard> {
  final _domainController = TextEditingController();
  final _keyController = TextEditingController();
  bool _custom = false;
  ServerSettings? _seededFrom;
  bool _busy = false;
  String? _testResult;

  @override
  void dispose() {
    _domainController.dispose();
    _keyController.dispose();
    super.dispose();
  }

  void _seed(ServerSettings stored) {
    _custom = stored.custom;
    _domainController.text = stored.domain;
    _keyController.text = stored.key;
    _seededFrom = stored;
  }

  bool _differs(ServerSettings stored) =>
      _custom != stored.custom ||
      _domainController.text.trim() != stored.domain ||
      _keyController.text.trim() != stored.key;

  Future<void> _save(AppStateProvider appState) async {
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    final error = await appState.setServer(ServerSettings(
      custom: _custom,
      domain: _domainController.text,
      key: _keyController.text,
    ));
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (error == null) _seed(appState.serverSettings);
    });
    if (error != null) {
      AppToast.error(context, error);
    } else if (appState.customServerActive) {
      AppToast.warning(context, 'Now using ${appState.serverName}');
    } else if (_custom) {
      AppToast.info(context, 'Saved. Still on Live until both fields are set');
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
    final result = await appState.testServer(
      domain: _domainController.text,
      key: _keyController.text,
    );
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

    final active = appState.customServerActive;
    final blocked = appState.serverChangeBlockedReason;
    final dirty = _differs(stored);
    final typedDomain = _domainController.text.trim();
    final domainError =
        typedDomain.isEmpty ? null : ServerConfig.domainProblem(typedDomain);

    return SettingsSectionCard(title: 'Server', children: [
      ListTile(
        leading: Icon(
          active ? Icons.science : Icons.cloud_done,
          color: active ? Colors.deepOrange : Colors.green,
        ),
        title: Text(active ? 'Custom server' : 'Live server'),
        subtitle: Text(appState.serverName),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
        child: SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: false, label: Text('Live')),
            ButtonSegment(value: true, label: Text('Custom')),
          ],
          selected: {_custom},
          onSelectionChanged: _busy
              ? null
              : (choice) => setState(() {
                    _custom = choice.first;
                    _testResult = null;
                  }),
        ),
      ),
      if (_custom) ...[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            controller: _domainController,
            enabled: !_busy,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.next,
            decoration: InputDecoration(
              labelText: 'Server URL',
              hintText: 'dev.example.org',
              helperText: 'https only. Host name, no path',
              errorText: domainError,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) => setState(() => _testResult = null),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
          child: TextField(
            controller: _keyController,
            enabled: !_busy,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(
              labelText: 'API key',
              helperText: 'The key of that server. Stored on this device',
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
            if (_custom)
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
              onPressed: _busy || !dirty || domainError != null
                  ? null
                  : () => _save(appState),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    ]);
  }
}

/// Shown at the top of the map for as long as a custom server is active, so
/// a real drive is never recorded on a test server by accident. It has no
/// close button and cannot be dismissed: it goes when the app is back on
/// Live.
class CustomServerBanner extends StatelessWidget {
  final String serverName;

  const CustomServerBanner({super.key, required this.serverName});

  @override
  Widget build(BuildContext context) {
    final inset = MediaQuery.of(context).padding;
    return Semantics(
      liveRegion: true,
      label: 'Test server $serverName. Nothing recorded now goes to the '
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
                'TEST SERVER  $serverName',
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
