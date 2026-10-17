import 'package:flutter/material.dart';

import '../utils/repeater_nicknames.dart';
import 'repeater_nickname_widgets.dart';

/// Asks for a nickname for the repeater shown as [hex] (named [serverName] by
/// the server), starting from [current].
///
/// Returns null when cancelled, '' when the user removed the nickname,
/// otherwise the normalized nickname.
Future<String?> showRepeaterNicknameDialog(
  BuildContext context, {
  required String hex,
  required String serverName,
  String? current,
}) {
  return showDialog<String>(
    context: context,
    builder: (_) => _RepeaterNicknameDialog(
      hex: hex,
      serverName: serverName,
      current: current,
    ),
  );
}

/// Whether a [showRepeaterNicknameDialog] [result] would change a repeater
/// whose nickname is [current].
///
/// The provider setters save and sync on every call, so callers skip a
/// cancel, the same nickname again, and a removal of nothing.
bool nicknameResultChanges(String? result, String? current) {
  if (result == null) return false;
  if (result.isEmpty) return current != null;
  return result != current;
}

class _RepeaterNicknameDialog extends StatefulWidget {
  const _RepeaterNicknameDialog({
    required this.hex,
    required this.serverName,
    this.current,
  });

  final String hex;
  final String serverName;
  final String? current;

  @override
  State<_RepeaterNicknameDialog> createState() =>
      _RepeaterNicknameDialogState();
}

class _RepeaterNicknameDialogState extends State<_RepeaterNicknameDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: widget.current ?? '');

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _save() {
    Navigator.of(context)
        .pop(RepeaterNicknames.normalizeNickname(_controller.text) ?? '');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final hex = widget.hex;
    final canRemove = widget.current != null;

    return AlertDialog(
      title: const Text('Repeater nickname'),
      scrollable: true,
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              RepeaterHexBadge(hex),
              if (widget.serverName.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    widget.serverName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLength: RepeaterNicknames.maxLength,
            textCapitalization: TextCapitalization.words,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: 'Mell',
              // Faded: the hint is a real-looking nickname, and at the
              // theme's full hint colour it read as one already typed in the
              // dark theme.
              hintStyle: TextStyle(
                  color: scheme.onSurfaceVariant.withValues(alpha: 0.6)),
              border: const OutlineInputBorder(),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 4),
          Text(
            'Shows instead of $hex in Top Heard, and as its name on the Live '
            'Activity, CarPlay, Apple Watch and Siri. If another repeater '
            'shares $hex, the ID shows instead.',
            style: theme.textTheme.bodySmall
                ?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
      actionsAlignment:
          canRemove ? MainAxisAlignment.spaceBetween : MainAxisAlignment.end,
      actions: [
        if (canRemove)
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => Navigator.of(context).pop(''),
            child: const Text('Remove'),
          ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 8),
            FilledButton(
              onPressed: _save,
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}
