import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

import 'scope_test_support.dart';

/// Debug logs ship with bug reports, and a public key is logged by its
/// 8-hex prefix only. The per-frame dump must keep to that for the frames
/// that carry a full contact record.
void main() {
  final key = Uint8List.fromList([for (var i = 0; i < 32; i++) 0x10 + i]);
  String hex(Iterable<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  for (final code in [ResponseCodes.contact, PushCodes.newAdvert]) {
    test('a frame 0x${code.toRadixString(16)} logs the key prefix only', () {
      final lines = captureScopeLog();
      onScopeClock(ScopeRadio.new, (async, radio, conn) {
        final payload = scopeContactPayload(pubkey: key);
        radio.emit([code, ...payload]);
        async.flushMicrotasks();
      });
      final frameLines =
          lines.where((l) => l.contains('[CONN] Frame 0x')).toList();
      expect(frameLines, hasLength(1));
      expect(frameLines.single, contains(hex([code, ...key.sublist(0, 4)])));
      final rest = hex(key.sublist(4));
      for (final line in lines) {
        expect(line, isNot(contains(rest)));
        expect(line, isNot(contains(hex(key.sublist(4, 8)))));
      }
    });
  }
}
