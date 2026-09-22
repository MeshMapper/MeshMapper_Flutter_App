import 'package:flutter/material.dart';

/// Keeps log-table content inside its assigned column without changing its
/// normal-size layout.
class LogTableCellFit extends StatelessWidget {
  const LogTableCellFit({
    super.key,
    required this.child,
    this.alignment = Alignment.center,
  });

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) {
    return ClipRect(
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: alignment,
        child: child,
      ),
    );
  }
}
