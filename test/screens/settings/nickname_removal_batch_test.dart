import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/screens/settings/repeater_nicknames_page.dart';
import 'package:mesh_mapper/utils/repeater_nicknames.dart';

void main() {
  final keyA = '5007${'A' * 60}';
  final keyB = '40E6${'B' * 60}';
  const mell = RepeaterNickname(
      nickname: 'Mell', name: 'Mellionnec Repeater', hex: '5007');
  const goar = RepeaterNickname(nickname: 'Goar', name: 'Goariva', hex: '40E6');

  test('one removal is named', () {
    final batch = NicknameRemovalBatch()..add(keyA, mell);
    expect(batch.message, 'Removed Mell');
  });

  test('a second removal joins the first, and Undo gets both', () {
    final batch = NicknameRemovalBatch()
      ..add(keyA, mell)
      ..add(keyB, goar);
    expect(batch.message, 'Removed 2 nicknames');

    final taken = batch.take();
    expect(taken, {keyA: mell, keyB: goar});
    expect(batch.take(), isEmpty, reason: 'take leaves the batch empty');
  });

  test('clear ends the batch without restoring', () {
    final batch = NicknameRemovalBatch()..add(keyA, mell);
    batch.clear();
    expect(batch.take(), isEmpty);
  });
}
