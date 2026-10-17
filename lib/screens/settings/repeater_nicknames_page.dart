import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../providers/app_state_provider.dart';
import '../../utils/public_key.dart';
import '../../utils/repeater_nicknames.dart';
import '../../widgets/repeater_nickname_dialog.dart';
import '../../widgets/repeater_nickname_widgets.dart';
import '../../widgets/repeater_picker_sheet.dart';
import 'settings_section_card.dart';

/// Settings > Map > Repeater Nicknames: every saved nickname, with add, edit
/// and remove. Entries may belong to repeaters outside the current zone, so
/// edits and removals go by key, not through the catalogue.
class RepeaterNicknamesPage extends StatelessWidget {
  const RepeaterNicknamesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final entries = context.watch<AppStateProvider>().repeaterNicknames;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 40,
        title: const Text('Repeater Nicknames', style: TextStyle(fontSize: 18)),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add nickname',
            onPressed: () => _add(context),
          ),
        ],
      ),
      body: RepeaterNicknameList(
        entries: entries,
        onAdd: () => _add(context),
        onEdit: (key, entry) => _edit(context, key, entry),
        onRemove: (key, entry) => _remove(context, key, entry),
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final appState = context.read<AppStateProvider>();
    final picked = await showRepeaterPicker(context);
    if (!context.mounted || picked == null) return;
    if (!isFullPublicKey(picked.hexId)) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text("This repeater's full key is unknown, "
            "so it can't have a nickname."),
      ));
      return;
    }
    final current = appState.nicknameForRepeater(picked);
    final result = await showRepeaterNicknameDialog(
      context,
      hex: picked.displayHexId(),
      serverName: picked.name,
      current: current,
    );
    if (!context.mounted || !nicknameResultChanges(result, current)) return;
    await appState.setRepeaterNickname(picked, result);
  }

  Future<void> _edit(
    BuildContext context,
    String key,
    RepeaterNickname entry,
  ) async {
    final appState = context.read<AppStateProvider>();
    final result = await showRepeaterNicknameDialog(
      context,
      hex: entry.hex,
      serverName: entry.name,
      current: entry.nickname,
    );
    if (!context.mounted || !nicknameResultChanges(result, entry.nickname)) {
      return;
    }
    await appState.setRepeaterNicknameByKey(key, result);
  }

  Future<void> _remove(
    BuildContext context,
    String key,
    RepeaterNickname entry,
  ) async {
    final appState = context.read<AppStateProvider>();
    final messenger = ScaffoldMessenger.of(context);
    await appState.setRepeaterNicknameByKey(key, null);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('Removed ${entry.nickname}'),
        // A snack bar with an action stays up until tapped unless told not
        // to; this one is a short offer, not a question.
        persist: false,
        action: SnackBarAction(
          label: 'Undo',
          onPressed: () => appState.setRepeaterNicknameByKey(
            key,
            entry.nickname,
            name: entry.name,
            hex: entry.hex,
          ),
        ),
      ));
  }
}

/// The nickname list itself, fed by the page so it can be built without the
/// provider: the saved [entries] (full key, entry) one row each, hex first,
/// like the paper list taped in the car, or a prompt to add one.
class RepeaterNicknameList extends StatelessWidget {
  const RepeaterNicknameList({
    super.key,
    required this.entries,
    required this.onEdit,
    required this.onRemove,
    required this.onAdd,
  });

  final List<MapEntry<String, RepeaterNickname>> entries;
  final void Function(String key, RepeaterNickname entry) onEdit;
  final void Function(String key, RepeaterNickname entry) onRemove;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    if (entries.isEmpty) {
      return Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.label_outline,
                  size: 40, color: scheme.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                'Give repeaters your own short names, like Mell for 5007. '
                'They show instead of the ID in Top Heard, on the Live '
                'Activity, CarPlay, Apple Watch and Siri.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              FilledButton.tonalIcon(
                icon: const Icon(Icons.add),
                label: const Text('Add nickname'),
                onPressed: onAdd,
              ),
              const SizedBox(height: 12),
              Text(
                'You can also tap a repeater on the map.',
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall
                    ?.copyWith(color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
      children: [
        SettingsSectionCard(title: 'Nicknames', children: [
          for (final e in entries)
            ListTile(
              leading: RepeaterHexBadge(e.value.hex),
              title: Text(
                e.value.nickname,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              subtitle: e.value.name.isEmpty ? null : Text(e.value.name),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: 'Remove',
                onPressed: () => onRemove(e.key, e.value),
              ),
              onTap: () => onEdit(e.key, e.value),
            ),
        ]),
      ],
    );
  }
}
