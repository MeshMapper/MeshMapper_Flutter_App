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
class RepeaterNicknamesPage extends StatefulWidget {
  const RepeaterNicknamesPage({super.key});

  @override
  State<RepeaterNicknamesPage> createState() => _RepeaterNicknamesPageState();
}

class _RepeaterNicknamesPageState extends State<RepeaterNicknamesPage> {
  final _removed = NicknameRemovalBatch();

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
            onPressed: _add,
          ),
        ],
      ),
      body: RepeaterNicknameList(
        entries: entries,
        onAdd: _add,
        onEdit: _edit,
        onRemove: _remove,
      ),
    );
  }

  Future<void> _add() async {
    final appState = context.read<AppStateProvider>();
    // Only repeaters with a full key can take a nickname, so the picker
    // offers no others.
    final picked = await showRepeaterPicker(context,
        include: (repeater) => isFullPublicKey(repeater.hexId));
    if (!mounted || picked == null) return;
    await editRepeaterNickname(context, appState, picked);
  }

  Future<void> _edit(String key, RepeaterNickname entry) async {
    final appState = context.read<AppStateProvider>();
    final result = await showRepeaterNicknameDialog(
      context,
      hex: entry.hex,
      serverName: entry.name,
      current: entry.nickname,
    );
    // The save needs no context, so a page closed under the dialog still
    // keeps what was typed.
    if (!nicknameResultChanges(result, entry.nickname)) return;
    await appState.setRepeaterNicknameByKey(key, result);
  }

  Future<void> _remove(String key, RepeaterNickname entry) async {
    final appState = context.read<AppStateProvider>();
    final messenger = ScaffoldMessenger.of(context);
    await appState.setRepeaterNicknameByKey(key, null);
    // A removal while the last one's bar is still up joins it, so one Undo
    // brings both back. Replacing the bar alone used to lose the first.
    final batch = _removed..add(key, entry);
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(SnackBar(
          content: Text(batch.message),
          // A snack bar with an action stays up until tapped unless told not
          // to; this one is a short offer, not a question.
          persist: false,
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () {
              for (final removed in batch.take().entries) {
                appState.setRepeaterNicknameByKey(
                  removed.key,
                  removed.value.nickname,
                  name: removed.value.name,
                  hex: removed.value.hex,
                );
              }
            },
          ),
        ))
        .closed
        .then((reason) {
      // Hidden means a newer removal replaced this bar and carries the batch
      // on. Anything else ends the offer.
      if (reason != SnackBarClosedReason.hide) batch.clear();
    });
  }
}

/// The removals the Settings list's current Undo bar covers, so one Undo
/// restores every nickname removed while it was up.
class NicknameRemovalBatch {
  final Map<String, RepeaterNickname> _entries = {};

  /// Adds [entry], removed from the repeater with full key [key].
  void add(String key, RepeaterNickname entry) => _entries[key] = entry;

  /// "Removed Mell" for one, "Removed 2 nicknames" for more.
  String get message => _entries.length == 1
      ? 'Removed ${_entries.values.single.nickname}'
      : 'Removed ${_entries.length} nicknames';

  /// Every removal in the batch, which is left empty.
  Map<String, RepeaterNickname> take() {
    final taken = Map.of(_entries);
    _entries.clear();
    return taken;
  }

  /// Ends the batch without restoring anything.
  void clear() => _entries.clear();
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
                'They show instead of the ID in Top Heard, and as the name '
                'on the Live Activity, CarPlay, Apple Watch and Siri.',
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
