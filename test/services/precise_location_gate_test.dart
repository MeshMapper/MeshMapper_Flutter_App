import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mesh_mapper/services/precise_location_gate.dart';

/// The Precise Location check made at Connect. The server refuses every fix
/// worse than 50 m, so a phone on approximate location maps nothing.
void main() {
  group('decidePreciseLocationStep', () {
    PreciseLocationStep decide({
      PreciseLocationPlatform platform = PreciseLocationPlatform.ios,
      bool simulatorEnabled = false,
      bool locationGranted = true,
      LocationAccuracyStatus? accuracy = LocationAccuracyStatus.precise,
      bool alreadyAsked = false,
      bool canPrompt = true,
    }) =>
        decidePreciseLocationStep(
          platform: platform,
          simulatorEnabled: simulatorEnabled,
          locationGranted: locationGranted,
          accuracy: accuracy,
          alreadyAsked: alreadyAsked,
          canPrompt: canPrompt,
        );

    test('precise location connects', () {
      expect(decide(), PreciseLocationStep.connect);
      expect(decide(platform: PreciseLocationPlatform.android),
          PreciseLocationStep.connect);
    });

    test('reduced on iOS asks for temporary full accuracy', () {
      expect(decide(accuracy: LocationAccuracyStatus.reduced),
          PreciseLocationStep.askTemporaryFullAccuracy);
    });

    test('still reduced after asking blocks the connect', () {
      expect(
          decide(accuracy: LocationAccuracyStatus.reduced, alreadyAsked: true),
          PreciseLocationStep.block);
    });

    test('reduced on Android re-requests fine location once', () {
      expect(
          decide(
            platform: PreciseLocationPlatform.android,
            accuracy: LocationAccuracyStatus.reduced,
          ),
          PreciseLocationStep.requestFineLocation);
    });

    test('reduced on Android after the re-request blocks', () {
      expect(
          decide(
            platform: PreciseLocationPlatform.android,
            accuracy: LocationAccuracyStatus.reduced,
            alreadyAsked: true,
          ),
          PreciseLocationStep.block);
    });

    test('reduced with no way to prompt blocks without asking', () {
      expect(decide(accuracy: LocationAccuracyStatus.reduced, canPrompt: false),
          PreciseLocationStep.block);
      expect(
          decide(
            platform: PreciseLocationPlatform.android,
            accuracy: LocationAccuracyStatus.reduced,
            canPrompt: false,
          ),
          PreciseLocationStep.block);
    });

    test('web skips the check', () {
      expect(
          decide(
            platform: PreciseLocationPlatform.web,
            accuracy: LocationAccuracyStatus.reduced,
          ),
          PreciseLocationStep.skip);
    });

    test('the GPS simulator skips the check', () {
      expect(
          decide(
            simulatorEnabled: true,
            accuracy: LocationAccuracyStatus.reduced,
          ),
          PreciseLocationStep.skip);
    });

    test('location not granted is left to the existing denied path', () {
      expect(
          decide(
            locationGranted: false,
            accuracy: LocationAccuracyStatus.reduced,
          ),
          PreciseLocationStep.skip);
    });

    test('an unreadable accuracy fails open', () {
      expect(decide(accuracy: null), PreciseLocationStep.connect);
      expect(decide(accuracy: LocationAccuracyStatus.unknown),
          PreciseLocationStep.connect);
    });
  });

  group('PreciseLocationGate', () {
    group('isApproximateOnly', () {
      PreciseLocationGate gate({
        bool granted = true,
        LocationAccuracyStatus accuracy = LocationAccuracyStatus.reduced,
        bool readThrows = false,
      }) =>
          PreciseLocationGate(
            checkGranted: () async => granted,
            readAccuracy: () async =>
                readThrows ? throw Exception('no plugin') : accuracy,
          );

      Future<bool> check(PreciseLocationGate g,
              {PreciseLocationPlatform platform =
                  PreciseLocationPlatform.android,
              bool simulator = false}) =>
          g.isApproximateOnly(platform: platform, simulatorEnabled: simulator);

      test('true for granted, reduced accuracy', () async {
        expect(await check(gate()), isTrue);
        expect(
            await check(gate(), platform: PreciseLocationPlatform.ios), isTrue);
      });

      test('false for precise, not granted, or a failed read', () async {
        expect(await check(gate(accuracy: LocationAccuracyStatus.precise)),
            isFalse);
        expect(await check(gate(granted: false)), isFalse);
        expect(await check(gate(readThrows: true)), isFalse);
      });

      test('false on web and with the GPS simulator', () async {
        expect(await check(gate(), platform: PreciseLocationPlatform.web),
            isFalse);
        expect(await check(gate(), simulator: true), isFalse);
      });
    });

    test('iOS: allowed after the temporary full accuracy prompt', () async {
      var asks = 0;
      final gate = PreciseLocationGate(
        checkGranted: () async => true,
        readAccuracy: () async => LocationAccuracyStatus.reduced,
        requestTemporaryFullAccuracy: () async {
          asks++;
          return LocationAccuracyStatus.precise;
        },
      );
      final allowed = await gate.allowsConnect(
        platform: PreciseLocationPlatform.ios,
        simulatorEnabled: false,
        canPrompt: true,
        entry: 'BLE',
      );
      expect(allowed, isTrue);
      expect(asks, 1);
    });

    test('iOS: declined prompt blocks, asking only once', () async {
      var asks = 0;
      final gate = PreciseLocationGate(
        checkGranted: () async => true,
        readAccuracy: () async => LocationAccuracyStatus.reduced,
        requestTemporaryFullAccuracy: () async {
          asks++;
          return LocationAccuracyStatus.reduced;
        },
      );
      final allowed = await gate.allowsConnect(
        platform: PreciseLocationPlatform.ios,
        simulatorEnabled: false,
        canPrompt: true,
        entry: 'BLE',
      );
      expect(allowed, isFalse);
      expect(asks, 1);
    });

    test('iOS: a failing prompt counts as declined', () async {
      final gate = PreciseLocationGate(
        checkGranted: () async => true,
        readAccuracy: () async => LocationAccuracyStatus.reduced,
        requestTemporaryFullAccuracy: () async =>
            throw Exception('purpose key missing'),
      );
      expect(
          await gate.allowsConnect(
            platform: PreciseLocationPlatform.ios,
            simulatorEnabled: false,
            canPrompt: true,
            entry: 'BLE',
          ),
          isFalse);
    });

    test('Android: allowed when the fine re-request upgrades it', () async {
      var accuracy = LocationAccuracyStatus.reduced;
      var requests = 0;
      final gate = PreciseLocationGate(
        checkGranted: () async => true,
        readAccuracy: () async => accuracy,
        requestTemporaryFullAccuracy: () async =>
            fail('iOS prompt used on Android'),
      );
      final allowed = await gate.allowsConnect(
        platform: PreciseLocationPlatform.android,
        simulatorEnabled: false,
        canPrompt: true,
        requestFineLocation: () async {
          requests++;
          accuracy = LocationAccuracyStatus.precise;
          return true;
        },
        entry: 'TCP',
      );
      expect(allowed, isTrue);
      expect(requests, 1);
    });

    test('Android: no re-request available blocks', () async {
      final gate = PreciseLocationGate(
        checkGranted: () async => true,
        readAccuracy: () async => LocationAccuracyStatus.reduced,
        requestTemporaryFullAccuracy: () async =>
            fail('iOS prompt used on Android'),
      );
      expect(
          await gate.allowsConnect(
            platform: PreciseLocationPlatform.android,
            simulatorEnabled: false,
            canPrompt: true,
            entry: 'USB',
          ),
          isFalse);
    });

    test('web never reads the platform', () async {
      final gate = PreciseLocationGate(
        checkGranted: () async => fail('permission read on web'),
        readAccuracy: () async => fail('accuracy read on web'),
        requestTemporaryFullAccuracy: () async => fail('prompt on web'),
      );
      expect(
          await gate.allowsConnect(
            platform: PreciseLocationPlatform.web,
            simulatorEnabled: false,
            canPrompt: true,
            entry: 'BLE',
          ),
          isTrue);
    });
  });
}
