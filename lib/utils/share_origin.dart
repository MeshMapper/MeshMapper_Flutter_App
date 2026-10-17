import 'package:flutter/widgets.dart';

/// Global rect of the widget behind [context], or null before layout.
///
/// Pass it as share_plus's `sharePositionOrigin`: iPad anchors the share
/// popover there and refuses to open the sheet without one.
Rect? globalRectOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
