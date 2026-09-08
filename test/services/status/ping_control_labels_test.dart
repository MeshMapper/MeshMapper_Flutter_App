import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/status/ping_control_labels.dart';

/// Every word the in-app ping buttons can show, pinned exactly as it ships
/// today. This table is the deliverable of the extraction, not the extraction
/// itself: it is what lets the next step change the shape of the code and
/// prove no label moved.
///
/// It pins the oddities on purpose. Where two buttons say different words about
/// the same instant, there is a row saying so.

PingControlFacts facts({
  bool isConnected = true,
  bool externalAntennaSet = true,
  bool isPowerSet = true,
  PingValidation validation = PingValidation.valid,
  bool isTxModeRunning = false,
  bool isPassiveModeRunning = false,
  bool isTargetedRunning = false,
  bool isPendingDisable = false,
  bool isPingSending = false,
  bool isPingInProgress = false,
  bool hybridEnabled = false,
  bool txBlockedByOffline = false,
  bool txNotAllowed = false,
  bool rxWindowActive = false,
  int rxWindowRemaining = 4,
  bool manualCooldownActive = false,
  int manualCooldownRemaining = 9,
  bool discoveryWindowActive = false,
  int discoveryWindowRemaining = 6,
  bool cooldownActive = false,
  int cooldownRemaining = 5,
  bool autoPingWaiting = false,
  int autoPingRemaining = 22,
  String? autoPingSkipReason,
}) =>
    (
      isConnected: isConnected,
      externalAntennaSet: externalAntennaSet,
      isPowerSet: isPowerSet,
      validation: validation,
      isTxModeRunning: isTxModeRunning,
      isPassiveModeRunning: isPassiveModeRunning,
      isTargetedRunning: isTargetedRunning,
      isPendingDisable: isPendingDisable,
      isPingSending: isPingSending,
      isPingInProgress: isPingInProgress,
      hybridEnabled: hybridEnabled,
      txBlockedByOffline: txBlockedByOffline,
      txNotAllowed: txNotAllowed,
      rxWindowActive: rxWindowActive,
      rxWindowRemaining: rxWindowRemaining,
      manualCooldownActive: manualCooldownActive,
      manualCooldownRemaining: manualCooldownRemaining,
      discoveryWindowActive: discoveryWindowActive,
      discoveryWindowRemaining: discoveryWindowRemaining,
      cooldownActive: cooldownActive,
      cooldownRemaining: cooldownRemaining,
      autoPingWaiting: autoPingWaiting,
      autoPingRemaining: autoPingRemaining,
      autoPingSkipReason: autoPingSkipReason,
    );

void main() {
  group('the blocking hint', () {
    test('says nothing while disconnected', () {
      // The buttons are obviously dead, so a reason would be noise.
      expect(blockingHint(facts(isConnected: false, externalAntennaSet: false)),
          isNull);
    });

    test('names each reason, in priority order', () {
      expect(blockingHint(facts(externalAntennaSet: false)),
          (hint: StatusHint.antennaRequired, text: 'Select antenna option'));
      expect(blockingHint(facts(isPowerSet: false)), (
        hint: StatusHint.powerRequired,
        text: 'Select power level in Connect tab'
      ));
      expect(blockingHint(facts(validation: PingValidation.airborne)),
          (hint: StatusHint.airborne, text: 'Airborne, wardriving blocked'));
      expect(blockingHint(facts(validation: PingValidation.noGpsLock)),
          (hint: StatusHint.noGpsLock, text: 'Waiting for GPS lock...'));
      expect(blockingHint(facts(validation: PingValidation.gpsInaccurate)),
          (hint: StatusHint.gpsInaccurate, text: 'GPS accuracy too low'));
    });

    test('the antenna reason outranks every other', () {
      expect(
        blockingHint(facts(
          externalAntennaSet: false,
          isPowerSet: false,
          validation: PingValidation.airborne,
        ))?.hint,
        StatusHint.antennaRequired,
      );
    });

    test('power outranks every validation reason', () {
      expect(
        blockingHint(facts(
          isPowerSet: false,
          validation: PingValidation.noGpsLock,
        ))?.hint,
        StatusHint.powerRequired,
      );
    });

    test('a valid ping needs no hint', () {
      expect(blockingHint(facts()), isNull);
    });

    test('cooldown and too-close are deliberately hintless', () {
      // They show on the button instead, which is why the chain skips them.
      expect(blockingHint(facts(validation: PingValidation.tooCloseToLastPing)),
          isNull);
      expect(blockingHint(facts(validation: PingValidation.recentlyCovered)),
          isNull);
    });

    test('the service-area reason exists but nothing can produce it', () {
      // No validator returns outsideGeofence, so this row is unreachable in the
      // app. Pinned so the dead branch is recorded rather than rediscovered.
      expect(blockingHint(facts(validation: PingValidation.outsideGeofence)),
          (hint: StatusHint.outsideServiceArea, text: 'Outside service area'));
    });
  });

  group('Send Ping', () {
    test('resting', () => expect(portraitSendPingLabel(facts()), 'Send Ping'));

    test('offline blocks TX', () {
      expect(portraitSendPingLabel(facts(txBlockedByOffline: true)),
          'TX Disabled');
    });

    test('a full zone, which the layout never lets through', () {
      expect(portraitSendPingLabel(facts(txNotAllowed: true)), 'Zone Full');
    });

    test('an auto TX mode greys it to the resting word', () {
      expect(portraitSendPingLabel(facts(isTxModeRunning: true)), 'Send Ping');
    });

    test('sending', () {
      expect(portraitSendPingLabel(facts(isPingSending: true)), 'Sending...');
    });

    test('its own listening window', () {
      expect(
          portraitSendPingLabel(facts(rxWindowActive: true)), 'Listening 4s');
    });

    test('all three cooldowns say the same word', () {
      expect(portraitSendPingLabel(facts(manualCooldownActive: true)),
          'Cooldown 9s');
      expect(portraitSendPingLabel(facts(discoveryWindowActive: true)),
          'Cooldown 6s');
      expect(portraitSendPingLabel(facts(cooldownActive: true)), 'Cooldown 5s');
    });
  });

  group('Active / Hybrid', () {
    test('resting, and the word follows the preference not the running mode',
        () {
      expect(portraitActiveModeLabel(facts()), 'Active Mode');
      expect(
          portraitActiveModeLabel(facts(hybridEnabled: true)), 'Hybrid Mode');
    });

    test('offline and full-zone blocks', () {
      expect(portraitActiveModeLabel(facts(txBlockedByOffline: true)),
          'TX Disabled');
      expect(portraitActiveModeLabel(facts(txNotAllowed: true)), 'Zone Full');
    });

    test('stopping, with and without a window to wait out', () {
      expect(
          portraitActiveModeLabel(
              facts(isPendingDisable: true, rxWindowActive: true)),
          'Stopping 4s');
      expect(
          portraitActiveModeLabel(
              facts(isPendingDisable: true, discoveryWindowActive: true)),
          'Stopping 6s');
      expect(portraitActiveModeLabel(facts(isPendingDisable: true)),
          'Stopping...');
    });

    test('sending, which needs no window open', () {
      expect(
          portraitActiveModeLabel(
              facts(isTxModeRunning: true, isPingInProgress: true)),
          'Sending...');
      // A window open means the send is done; listening wins.
      expect(
          portraitActiveModeLabel(facts(
              isTxModeRunning: true,
              isPingInProgress: true,
              rxWindowActive: true)),
          'Listening 4s');
    });

    test('listening, from either window', () {
      expect(
          portraitActiveModeLabel(
              facts(isTxModeRunning: true, discoveryWindowActive: true)),
          'Listening 6s');
      expect(
          portraitActiveModeLabel(
              facts(isTxModeRunning: true, rxWindowActive: true)),
          'Listening 4s');
    });

    test('waiting, deferred and skipped', () {
      expect(
          portraitActiveModeLabel(
              facts(isTxModeRunning: true, autoPingWaiting: true)),
          'Next ping 22s');
      expect(
          portraitActiveModeLabel(facts(
              isTxModeRunning: true,
              autoPingWaiting: true,
              autoPingSkipReason: PingService.skipReasonRecentlyCovered)),
          'Deferred 22s');
      expect(
          portraitActiveModeLabel(facts(
              isTxModeRunning: true,
              autoPingWaiting: true,
              autoPingSkipReason: 'too close')),
          'Skipped 22s');
    });

    test('running but between cycles falls back to the mode word', () {
      expect(
          portraitActiveModeLabel(facts(isTxModeRunning: true)), 'Active Mode');
    });

    test('not running, it borrows the two idle cooldowns', () {
      expect(
          portraitActiveModeLabel(facts(rxWindowActive: true)), 'Cooldown 4s');
      expect(
          portraitActiveModeLabel(facts(cooldownActive: true)), 'Cooldown 5s');
    });
  });

  group('Passive', () {
    test('resting', () {
      expect(portraitPassiveModeLabel(facts()), 'Passive Mode');
    });

    test('listening for discovery responses', () {
      expect(
          portraitPassiveModeLabel(
              facts(isPassiveModeRunning: true, discoveryWindowActive: true)),
          'Listening 6s');
    });

    test('waiting, deferred and skipped', () {
      expect(
          portraitPassiveModeLabel(
              facts(isPassiveModeRunning: true, autoPingWaiting: true)),
          'Next Disc 22s');
      expect(
          portraitPassiveModeLabel(facts(
              isPassiveModeRunning: true,
              autoPingWaiting: true,
              autoPingSkipReason: PingService.skipReasonRecentlyCovered)),
          'Deferred 22s');
      expect(
          portraitPassiveModeLabel(facts(
              isPassiveModeRunning: true,
              autoPingWaiting: true,
              autoPingSkipReason: 'too close')),
          'Skipped 22s');
    });

    test('running before the first discovery shows the mode word', () {
      expect(portraitPassiveModeLabel(facts(isPassiveModeRunning: true)),
          'Passive Mode');
    });

    test('a TX mode or a stop greys it to the mode word', () {
      expect(portraitPassiveModeLabel(facts(isTxModeRunning: true)),
          'Passive Mode');
      expect(portraitPassiveModeLabel(facts(isPendingDisable: true)),
          'Passive Mode');
      // Even with a countdown running, which is what makes it a mode word and
      // not a cooldown.
      expect(
          portraitPassiveModeLabel(
              facts(isTxModeRunning: true, cooldownActive: true)),
          'Passive Mode');
    });

    test('idle, it borrows the two cooldowns', () {
      expect(
          portraitPassiveModeLabel(facts(rxWindowActive: true)), 'Cooldown 4s');
      expect(
          portraitPassiveModeLabel(facts(cooldownActive: true)), 'Cooldown 5s');
    });
  });

  group('what the buttons say about each other', () {
    test('one RX window, two words, side by side', () {
      // A manual ping during an idle session: its own button calls the window
      // listening, the two beside it call the same window a cooldown. Pinned
      // because it is one of the disagreements the vocabulary work has to
      // settle, and because it must not move before then.
      final f = facts(rxWindowActive: true);
      expect(portraitSendPingLabel(f), 'Listening 4s');
      expect(portraitActiveModeLabel(f), 'Cooldown 4s');
      expect(portraitPassiveModeLabel(f), 'Cooldown 4s');
    });

    test('one discovery window, two words', () {
      final f = facts(isPassiveModeRunning: true, discoveryWindowActive: true);
      expect(portraitPassiveModeLabel(f), 'Listening 6s');
      expect(portraitSendPingLabel(f), 'Cooldown 6s');
    });

    test('the same wait is Next ping on one button and Next Disc on another',
        () {
      expect(
          portraitActiveModeLabel(
              facts(isTxModeRunning: true, autoPingWaiting: true)),
          'Next ping 22s');
      expect(
          portraitPassiveModeLabel(
              facts(isPassiveModeRunning: true, autoPingWaiting: true)),
          'Next Disc 22s');
    });
  });

  test('the paused word tells a hold apart from a drop', () {
    expect(pausedWord(PingService.skipReasonRecentlyCovered), 'Deferred');
    expect(pausedWord('too close'), 'Skipped');
    expect(pausedWord(null), 'Skipped');
  });
}
