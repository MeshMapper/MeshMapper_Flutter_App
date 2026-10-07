import 'dart:typed_data';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/meshcore/connection.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

import 'fake_companion_transport.dart';

/// A fake radio that answers stats requests with a noise floor reading
/// while [answerStats] is true, and whose writes fail while [failWrites] is.
class _StatsRadio extends FakeCompanionTransport {
  bool answerStats = false;
  int statsWrites = 0;

  @override
  Future<void> write(Uint8List data) async {
    await super.write(data);
    if (data.first == CommandCodes.getStats) {
      statsWrites++;
      if (answerStats) {
        emit([
          ResponseCodes.stats,
          StatsTypes.radio,
          (-110) & 0xFF,
          ((-110) >> 8) & 0xFF,
          0, 0, 0, 0, 0, 0, 0, 0, 0,
        ]);
      }
    }
  }
}

void main() {
  group('noise floor polling', () {
    test('backs off after 3 failures and recovers on success', () {
      fakeAsync((async) {
        final radio = _StatsRadio()..failWrites = true;
        final connection = MeshCoreConnection(transport: radio);
        connection.debugStartNoiseFloorPolling();

        // Initial fetch plus two 5 s ticks: three failures in a row.
        async.elapse(const Duration(seconds: 11));
        expect(connection.isNoiseFloorPolling, isTrue);
        expect(connection.isNoiseFloorBackedOff, isTrue);

        // Backed off: nothing more within the next 25 s.
        final writesAtBackoff = radio.statsWrites;
        radio.failWrites = false;
        radio.answerStats = true;
        async.elapse(const Duration(seconds: 25));
        expect(radio.statsWrites, writesAtBackoff);

        // The 30 s tick succeeds and polling returns to 5 s.
        async.elapse(const Duration(seconds: 6));
        expect(connection.isNoiseFloorBackedOff, isFalse);
        expect(connection.lastNoiseFloor, -110);
        final afterRecovery = radio.statsWrites;
        async.elapse(const Duration(seconds: 10));
        expect(radio.statsWrites, afterRecovery + 2);

        connection.dispose();
        radio.dispose();
      });
    });
  });

  group('setChannel', () {
    Uint8List key() => Uint8List(16);

    test('completes on the radio OK', () async {
      final radio = FakeCompanionTransport();
      final connection = MeshCoreConnection(transport: radio);
      var done = false;
      final f = connection.setChannel(3, '#wardriving', key()).then((_) {
        done = true;
      });
      await radio.settle();
      expect(radio.commandAt(0), CommandCodes.setChannel);
      expect(done, isFalse);
      radio.emit([ResponseCodes.ok]);
      await f;
      expect(done, isTrue);
      connection.dispose();
      radio.dispose();
    });

    test('throws CommandErrorException on ERR', () async {
      final radio = FakeCompanionTransport();
      final connection = MeshCoreConnection(transport: radio);
      final f = connection.setChannel(3, '#wardriving', key());
      final expectation =
          expectLater(f, throwsA(isA<CommandErrorException>()));
      await radio.settle();
      radio.emit([ResponseCodes.err, ErrorCodes.notFound]);
      await expectation;
      connection.dispose();
      radio.dispose();
    });

    test('a silent delete gives up after its short timeout', () {
      fakeAsync((async) {
        final radio = FakeCompanionTransport();
        final connection = MeshCoreConnection(transport: radio);
        var done = false;
        Object? error;
        connection.deleteChannel(3).then<void>((_) {
          done = true;
        }, onError: (Object e) {
          error = e;
        });
        async.elapse(const Duration(milliseconds: 1400));
        expect(done, isFalse);
        async.elapse(const Duration(milliseconds: 200));
        expect(done, isTrue);
        expect(error, isNull);
        connection.dispose();
        radio.dispose();
      });
    });
  });
}
