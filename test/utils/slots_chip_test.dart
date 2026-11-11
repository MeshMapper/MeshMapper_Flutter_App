import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/utils/slots_chip.dart';

void main() {
  SlotsChipState chip({
    bool auth = false,
    bool? zone,
    int? available,
    int? max,
  }) =>
      slotsChipState(
        authFloodDisabled: auth,
        zoneFloodDisabled: zone,
        slotsAvailable: available,
        slotsMax: max,
      );

  test('flood on with slots shows the open count', () {
    final s = chip(zone: false, available: 2, max: 3);
    expect(s.kind, SlotsChipKind.open);
    expect(s.label, '2/3 Open');
    expect(s.color, Colors.orange);
    expect(s.tappable, isFalse);
  });

  test('flood on with 0 slots shows 0 Slots, not Flood Off', () {
    final s = chip(zone: false, available: 0, max: 0);
    expect(s.kind, SlotsChipKind.zeroSlots);
    expect(s.label, '0 Slots');
    expect(s.color, Colors.blue);
    expect(s.tappable, isFalse);
  });

  test('status flood_disabled true shows Flood Off even with slots', () {
    final s = chip(zone: true, available: 3, max: 3);
    expect(s.kind, SlotsChipKind.floodOff);
    expect(s.label, 'Flood Off');
    expect(s.color, Colors.blue);
    expect(s.tappable, isTrue);
  });

  test('auth floodDisabled outranks a status flood-on answer', () {
    final s = chip(auth: true, zone: false, available: 3, max: 3);
    expect(s.kind, SlotsChipKind.floodOff);
    expect(s.tappable, isTrue);
  });

  test('key absent with 0 slots keeps the legacy Flood Off guess', () {
    final s = chip(available: 0, max: 0);
    expect(s.kind, SlotsChipKind.floodOff);
    expect(s.label, 'Flood Off');
  });

  test('key absent with slots shows the open count', () {
    final s = chip(available: 5, max: 5);
    expect(s.kind, SlotsChipKind.open);
    expect(s.label, '5/5 Open');
    expect(s.color, Colors.green);
  });

  test('a full zone with flood on stays red', () {
    final s = chip(zone: false, available: 0, max: 3);
    expect(s.kind, SlotsChipKind.open);
    expect(s.color, Colors.red);
  });

  test('no slot data shows --', () {
    final s = chip(zone: false);
    expect(s.kind, SlotsChipKind.unknown);
    expect(s.label, '--');
    expect(s.color, Colors.grey);
  });
}
