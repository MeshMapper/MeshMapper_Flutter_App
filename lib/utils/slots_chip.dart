import 'package:flutter/material.dart';

/// What the Connection screen's slots chip shows.
enum SlotsChipKind {
  /// Flood is off for this zone's radio preset. Taps to the info sheet.
  floodOff,

  /// Flood is on but the preset hands out no TX slots. A regional setting,
  /// not a full zone, so it reads as info rather than an error.
  zeroSlots,

  /// A normal `x/y Open` count.
  open,

  /// No slot data yet.
  unknown,
}

class SlotsChipState {
  final SlotsChipKind kind;
  final String label;
  final IconData icon;
  final Color color;

  const SlotsChipState(this.kind, this.label, this.icon, this.color);

  bool get tappable => kind == SlotsChipKind.floodOff;
}

/// Decides the slots chip from the zone's capacity and flood flags.
///
/// [authFloodDisabled] is the live /auth veto. [zoneFloodDisabled] is the
/// zone's `flood_disabled` for the current preset, null when the server did
/// not send the key; only then is `slotsMax == 0` taken to mean flood off,
/// since per-preset slots let a preset have 0 slots with flood still on.
SlotsChipState slotsChipState({
  required bool authFloodDisabled,
  required bool? zoneFloodDisabled,
  required int? slotsAvailable,
  required int? slotsMax,
}) {
  final floodOff = authFloodDisabled || (zoneFloodDisabled ?? slotsMax == 0);
  if (floodOff) {
    return const SlotsChipState(
        SlotsChipKind.floodOff, 'Flood Off', Icons.waves, Colors.blue);
  }
  if (slotsMax == 0) {
    return const SlotsChipState(
        SlotsChipKind.zeroSlots, '0 Slots', Icons.people_outline, Colors.blue);
  }
  if (slotsAvailable == null || slotsMax == null) {
    return const SlotsChipState(
        SlotsChipKind.unknown, '--', Icons.people_outline, Colors.grey);
  }
  final Color color;
  if (slotsAvailable == 0) {
    color = Colors.red;
  } else if (slotsAvailable <= 2) {
    color = Colors.orange;
  } else {
    color = Colors.green;
  }
  return SlotsChipState(SlotsChipKind.open, '$slotsAvailable/$slotsMax Open',
      Icons.people_outline, color);
}
