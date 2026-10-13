import 'package:flutter/material.dart';

import '../models/repeater_scope.dart';

/// The repeater detail sheet's Scopes row: one chip per scope, the default
/// starred, folded after [kRepeaterScopeChipsShown] behind a "+N more" chip.
/// Tapping a chip says where it came from. Pure display: it reads the chips
/// it is given and changes no app state.
class RepeaterScopeChips extends StatefulWidget {
  final List<RepeaterScopeChip> chips;

  const RepeaterScopeChips({super.key, required this.chips});

  @override
  State<RepeaterScopeChips> createState() => _RepeaterScopeChipsState();
}

class _RepeaterScopeChipsState extends State<RepeaterScopeChips> {
  bool _expanded = false;

  static const Color _star = Color(0xFFE8B923);

  void _showDetails(RepeaterScopeChip chip) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(chip.label == '?' ? 'Default scope' : chip.label),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final line in chip.details)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(line),
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, Widget child, {VoidCallback? onTap}) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHighest,
      shape: StadiumBorder(
        side: BorderSide(color: scheme.outlineVariant),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 12),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final chips = widget.chips;
    final folded =
        !_expanded && chips.length > kRepeaterScopeChipsShown;
    final shown =
        folded ? chips.take(kRepeaterScopeChipsShown).toList() : chips;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final c in shown)
          _chip(
            context,
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (c.label != '?') Text(c.label),
                if (c.isDefault)
                  Padding(
                    padding: EdgeInsets.only(left: c.label == '?' ? 0 : 3),
                    child: const Text('★', style: TextStyle(color: _star)),
                  ),
                if (c.label == '?') const Text(' ?'),
              ],
            ),
            onTap: () => _showDetails(c),
          ),
        if (folded)
          _chip(
            context,
            Text('+${chips.length - kRepeaterScopeChipsShown} more'),
            onTap: () => setState(() => _expanded = true),
          ),
      ],
    );
  }
}
