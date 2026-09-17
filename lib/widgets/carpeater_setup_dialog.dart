import 'package:flutter/material.dart';

import '../providers/app_state_provider.dart';
import '../utils/debug_logger_io.dart';
import '../utils/public_key.dart';
import 'app_toast.dart';
import 'repeater_picker_sheet.dart';

Future<void> showCarpeaterSetupDialog(
  BuildContext context,
  AppStateProvider appState,
) async {
  if (appState.autoPingEnabled) {
    AppToast.warning(
      context,
      'Stop the current wardriving mode before changing your CARpeater.',
    );
    return;
  }

  await showDialog<void>(
    context: context,
    builder: (dialogContext) => _CarpeaterSetupDialog(appState: appState),
  );
}

class _CarpeaterSetupDialog extends StatefulWidget {
  const _CarpeaterSetupDialog({required this.appState});

  final AppStateProvider appState;

  @override
  State<_CarpeaterSetupDialog> createState() => _CarpeaterSetupDialogState();
}

class _CarpeaterSetupDialogState extends State<_CarpeaterSetupDialog> {
  late final TextEditingController _controller;

  AppStateProvider get _appState => widget.appState;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(
      text: _appState.preferences.carpeaterPublicKey ?? '',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _chooseRepeater() async {
    final picked = await showRepeaterPicker(context);
    if (!mounted || picked == null) return;
    final key = normalizePublicKey(picked.hexId);
    if (key == null) {
      AppToast.warning(
        context,
        'That repeater has no full key in the list. Paste it instead.',
      );
      return;
    }
    setState(() => _controller.text = key);
    debugLog(
      '[SETTINGS] CARpeater picked from list: ${key.substring(0, 8)}',
    );
  }

  void _save() {
    final text = _controller.text.trim();
    if (text.isEmpty) {
      _appState.updatePreferences(_appState.preferences.copyWith(
        clearCarpeaterPublicKey: true,
        ignoreCarpeater: false,
      ));
      // Clearing the field is the same answer as the re-entry prompt's
      // "I don't use a CARpeater", and it takes the same provider path. The
      // provider only dismisses the prompt when a key is SET, so without this
      // the "filter reset" dialog came back after every connect.
      _appState.dismissCarpeaterReentry();
      debugLog('[SETTINGS] CARpeater key cleared');
      Navigator.of(context).pop();
      return;
    }

    final key = normalizePublicKey(text);
    if (key == null) {
      AppToast.warning(context, 'Enter the full 64-character public key.');
      return;
    }

    _appState.updatePreferences(_appState.preferences.copyWith(
      carpeaterPublicKey: key,
      ignoreCarpeater: true,
    ));
    debugLog('[SETTINGS] CARpeater key set: ${key.substring(0, 8)}');
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final hasList = _appState.repeaters.isNotEmpty;
    return AlertDialog(
      title: const Text('My CARpeater'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          OutlinedButton.icon(
            icon: const Icon(Icons.search),
            label: const Text('Choose from repeater list'),
            onPressed: hasList ? _chooseRepeater : null,
          ),
          if (!hasList)
            Padding(
              padding: const EdgeInsets.only(top: 4, bottom: 4),
              child: Text(
                'Connect once to load the repeater list, or paste the key below.',
                style: TextStyle(fontSize: 12, color: Colors.grey[600]),
              ),
            ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            decoration: const InputDecoration(
              labelText: 'Public key',
              hintText: '64 hex characters',
              border: OutlineInputBorder(),
            ),
            maxLines: 2,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 13),
            textCapitalization: TextCapitalization.characters,
            onChanged: (value) {
              final stripped = value.replaceFirst(RegExp(r'^\s*(0[xX]|!)'), '');
              final filtered =
                  stripped.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
              if (filtered != value) {
                _controller.value = _controller.value.copyWith(
                  text: filtered,
                  selection: TextSelection.collapsed(offset: filtered.length),
                );
              }
            },
          ),
          const SizedBox(height: 8),
          Text(
            'The key is shared with MeshMapper so every wardriver in your '
            'region filters it too. Packets through your own CARpeater are '
            'stripped to credit the repeater behind it.',
            style: TextStyle(fontSize: 12, color: Colors.grey[600]),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
