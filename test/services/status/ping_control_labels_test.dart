import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/status/ping_control_labels.dart'
    show StatusHint;
import 'package:mesh_mapper/services/status/ping_control_labels.dart' as labels;
import 'package:mesh_mapper/services/status/session_status.dart';
import 'package:mesh_mapper/services/status/session_status_resolver.dart';

/// Every word the in-app ping buttons can show, pinned exactly as it ships
/// today. This table is the oracle: the strings below do not move, whatever the
/// code underneath does. The renderers now read the shared [SessionStatus], so
/// the flat knobs here are turned into a real model through [_status] (the same
/// mapping the widget makes) and the six render-facts through [_render]; the
/// assertions themselves are unchanged from when the chains read raw timers.

/// The flat knobs each row still expresses itself in. The same shape the
/// extraction used, so the assertion bodies did not have to change.
typedef Knobs = ({
  bool isConnected,
  bool externalAntennaSet,
  bool isPowerSet,
  bool isTxModeRunning,
  bool isPassiveModeRunning,
  bool isTargetedRunning,
  bool isPendingDisable,
  bool isPingSending,
  bool isPingInProgress,
  bool hybridEnabled,
  bool txBlockedByOffline,
  bool txNotAllowed,
  bool rxWindowActive,
  int rxWindowRemaining,
  bool manualCooldownActive,
  int manualCooldownRemaining,
  bool discoveryWindowActive,
  int discoveryWindowRemaining,
  bool cooldownActive,
  int cooldownRemaining,
  bool autoPingWaiting,
  int autoPingRemaining,
  String? autoPingSkipReason,
});

Knobs facts({
  bool isConnected = true,
  bool externalAntennaSet = true,
  bool isPowerSet = true,
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

final _epoch = DateTime.utc(2026, 1, 1, 12);

StatusDeadline? _dl(bool running, int rem) =>
    running ? (endsAt: _epoch, durationMs: null, remainingSec: rem) : null;

/// Build the shared model from the flat knobs, exactly as the widget does. The
/// one non-obvious step: a TX mode with a discovery window open can only be
/// Hybrid, since Active never opens one, so that combination resolves to Hybrid.
SessionStatus _status(Knobs k) {
  final autoMode = k.isTargetedRunning
      ? AutoMode.targeted
      : k.isPassiveModeRunning
          ? AutoMode.passive
          : k.isTxModeRunning
              ? (k.hybridEnabled || k.discoveryWindowActive
                  ? AutoMode.hybrid
                  : AutoMode.active)
              : AutoMode.active;
  final isSessionActive =
      k.isTxModeRunning || k.isPassiveModeRunning || k.isTargetedRunning;
  return resolveSessionStatus(
    isInZoneGracePeriod: false,
    zoneGraceEndsAt: null,
    isZoneTransferInProgress: false,
    isAutoReconnecting: false,
    connectionStep:
        k.isConnected ? ConnectionStep.connected : ConnectionStep.disconnected,
    isConnected: k.isConnected,
    isPendingDisable: k.isPendingDisable,
    isGpsLocked: true,
    autoMode: autoMode,
    txAllowed: !k.txNotAllowed,
    // Lane views ignore this; only the glance projection reads it, so its value
    // never reaches a button label.
    isManualSession: !isSessionActive,
    isPingSending: k.isPingSending,
    isPingInProgress: k.isPingInProgress,
    isRxWindowRunning: k.rxWindowActive,
    rxWindow: _dl(k.rxWindowActive, k.rxWindowRemaining),
    isDiscoveryWindowRunning: k.discoveryWindowActive,
    discoveryWindow: _dl(k.discoveryWindowActive, k.discoveryWindowRemaining),
    isManualCooldownRunning: k.manualCooldownActive,
    manualCooldown: _dl(k.manualCooldownActive, k.manualCooldownRemaining),
    isAutoPingRunning: k.autoPingWaiting,
    autoPingSkipReason: k.autoPingSkipReason,
    autoPing: _dl(k.autoPingWaiting, k.autoPingRemaining),
    isSharedCooldownRunning: k.cooldownActive,
    sharedCooldown: _dl(k.cooldownActive, k.cooldownRemaining),
    operation: null,
    isSessionStarting: false,
    isSessionActive: isSessionActive,
  );
}

labels.PingRenderFacts _render(Knobs k) => (
      txBlockedByOffline: k.txBlockedByOffline,
      txNotAllowed: k.txNotAllowed,
      hybridEnabled: k.hybridEnabled,
      isTxModeRunning: k.isTxModeRunning,
      isPassiveModeRunning: k.isPassiveModeRunning,
      isTargetedRunning: k.isTargetedRunning,
      isPendingDisable: k.isPendingDisable,
    );

// Thin adapters so every assertion below reads exactly as it did when the
// chains took the flat facts. Each builds the model and the render-facts and
// calls the real renderer.
({StatusHint hint, String text})? blockingHint(Knobs k, PingValidation v) =>
    labels.blockingHint(
        (
          isConnected: k.isConnected,
          externalAntennaSet: k.externalAntennaSet,
          isPowerSet: k.isPowerSet,
        ),
        v);

String pausedWord(String? skipReason) => labels.pausedWord(skipReason);

String portraitSendPingLabel(Knobs k) =>
    labels.portraitSendPingLabel(_status(k), _render(k));
String portraitActiveModeLabel(Knobs k) =>
    labels.portraitActiveModeLabel(_status(k), _render(k));
String portraitPassiveModeLabel(Knobs k) =>
    labels.portraitPassiveModeLabel(_status(k), _render(k));

String? compactSendPingLabel(Knobs k, {required bool showFullText}) =>
    labels.compactSendPingLabel(_status(k), _render(k),
        showFullText: showFullText);
String? compactActiveModeLabel(Knobs k,
        {required bool showFullText, required bool isExpandedDuringCooldown}) =>
    labels.compactActiveModeLabel(_status(k), _render(k),
        showFullText: showFullText,
        isExpandedDuringCooldown: isExpandedDuringCooldown);
String? compactPassiveModeLabel(Knobs k,
        {required bool showFullText, required bool isExpandedDuringCooldown}) =>
    labels.compactPassiveModeLabel(_status(k), _render(k),
        showFullText: showFullText,
        isExpandedDuringCooldown: isExpandedDuringCooldown);
String? compactTraceModeLabel(Knobs k,
        {required bool showFullText, required bool isExpandedDuringCooldown}) =>
    labels.compactTraceModeLabel(_status(k), _render(k),
        showFullText: showFullText,
        isExpandedDuringCooldown: isExpandedDuringCooldown);

String? traceStatusText(Knobs k) => labels.traceStatusText(_status(k), _render(k));
String traceSectionLabel(Knobs k, {required bool isStarting}) =>
    labels.traceSectionLabel(_status(k), _render(k), isStarting: isStarting);

int? landscapeSendPingCountdown(Knobs k) =>
    labels.landscapeSendPingCountdown(_status(k), _render(k));
int? landscapeActiveModeCountdown(Knobs k) =>
    labels.landscapeActiveModeCountdown(_status(k), _render(k));
int? landscapePassiveModeCountdown(Knobs k) =>
    labels.landscapePassiveModeCountdown(_status(k), _render(k));

void main() {
  group('the blocking hint', () {
    test('says nothing while disconnected', () {
      // The buttons are obviously dead, so a reason would be noise.
      expect(
          blockingHint(facts(isConnected: false, externalAntennaSet: false),
              PingValidation.valid),
          isNull);
    });

    test('names each reason, in priority order', () {
      expect(
          blockingHint(facts(externalAntennaSet: false), PingValidation.valid),
          (hint: StatusHint.antennaRequired, text: 'Select antenna option'));
      expect(blockingHint(facts(isPowerSet: false), PingValidation.valid), (
        hint: StatusHint.powerRequired,
        text: 'Select power level in Connect tab'
      ));
      expect(blockingHint(facts(), PingValidation.airborne),
          (hint: StatusHint.airborne, text: 'Airborne, wardriving blocked'));
      expect(blockingHint(facts(), PingValidation.noGpsLock),
          (hint: StatusHint.noGpsLock, text: 'Waiting for GPS'));
      expect(blockingHint(facts(), PingValidation.gpsInaccurate),
          (hint: StatusHint.gpsInaccurate, text: 'GPS signal is weak'));
    });

    test('the antenna reason outranks every other', () {
      expect(
        blockingHint(
                facts(
                  externalAntennaSet: false,
                  isPowerSet: false,
                ),
                PingValidation.airborne)
            ?.hint,
        StatusHint.antennaRequired,
      );
    });

    test('power outranks every validation reason', () {
      expect(
        blockingHint(
                facts(
                  isPowerSet: false,
                ),
                PingValidation.noGpsLock)
            ?.hint,
        StatusHint.powerRequired,
      );
    });

    test('a valid ping needs no hint', () {
      expect(blockingHint(facts(), PingValidation.valid), isNull);
    });

    test('cooldown and too-close are deliberately hintless', () {
      // They show on the button instead, which is why the chain skips them.
      expect(blockingHint(facts(), PingValidation.tooCloseToLastPing), isNull);
      expect(blockingHint(facts(), PingValidation.recentlyCovered), isNull);
    });

    test('the service-area reason exists but nothing can produce it', () {
      // No validator returns outsideGeofence, so this row is unreachable in the
      // app. Pinned so the dead branch is recorded rather than rediscovered.
      expect(blockingHint(facts(), PingValidation.outsideGeofence),
          (hint: StatusHint.outsideServiceArea, text: 'Outside a zone'));
    });
  });

  group('Send Ping', () {
    test('resting', () => expect(portraitSendPingLabel(facts()), 'Send Ping'));

    test('offline reads as Passive only', () {
      expect(portraitSendPingLabel(facts(txBlockedByOffline: true)),
          'Passive only');
    });

    test('a full zone reads as Passive only', () {
      expect(portraitSendPingLabel(facts(txNotAllowed: true)), 'Passive only');
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

    test('offline and full-zone both read as Passive only', () {
      expect(portraitActiveModeLabel(facts(txBlockedByOffline: true)),
          'Passive only');
      expect(portraitActiveModeLabel(facts(txNotAllowed: true)), 'Passive only');
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

    test('a deferring attempt holds Deferred through its pre-transmit gap', () {
      // The interval timer has fired and not rescheduled, so autoPingWaiting is
      // momentarily false while the deferring attempt reads a fresh fix. The
      // button must keep reading Deferred, not flash the bare mode word
      // ("Hybrid Mode") that the resting state renders.
      expect(
          portraitActiveModeLabel(facts(
              isTxModeRunning: true,
              hybridEnabled: true,
              isPingInProgress: true,
              autoPingWaiting: false,
              autoPingSkipReason: PingService.skipReasonRecentlyCovered)),
          startsWith('Deferred'));
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
          'Next disc 22s');
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

    test('the same wait is Next ping on one button and Next disc on another',
        () {
      expect(
          portraitActiveModeLabel(
              facts(isTxModeRunning: true, autoPingWaiting: true)),
          'Next ping 22s');
      expect(
          portraitPassiveModeLabel(
              facts(isPassiveModeRunning: true, autoPingWaiting: true)),
          'Next disc 22s');
    });
  });

  group('compact', () {
    test('every countdown keeps its "s", only two states collapse to dots', () {
      expect(
          compactSendPingLabel(facts(rxWindowActive: true),
              showFullText: false),
          '4s');
      expect(
          compactSendPingLabel(facts(isPingSending: true), showFullText: false),
          '...');
      expect(
          compactActiveModeLabel(facts(isPendingDisable: true),
              showFullText: false, isExpandedDuringCooldown: false),
          '...');
    });

    test('there is no resting word at all', () {
      // Collapsed or expanded, an idle compact button is its icon alone.
      expect(compactSendPingLabel(facts(), showFullText: true), isNull);
      expect(
          compactActiveModeLabel(facts(),
              showFullText: true, isExpandedDuringCooldown: false),
          isNull);
      expect(
          compactPassiveModeLabel(facts(),
              showFullText: true, isExpandedDuringCooldown: false),
          isNull);
    });

    test('Send Ping mirrors portrait word for word', () {
      expect(
          compactSendPingLabel(facts(isPingSending: true), showFullText: true),
          'Sending...');
      expect(
          compactSendPingLabel(facts(rxWindowActive: true), showFullText: true),
          'Listening 4s');
      expect(
          compactSendPingLabel(facts(manualCooldownActive: true),
              showFullText: true),
          'Cooldown 9s');
    });

    test('Active/Hybrid: stopping, sending, listening', () {
      String? label(Knobs f) => compactActiveModeLabel(f,
          showFullText: true, isExpandedDuringCooldown: false);
      expect(label(facts(isPendingDisable: true, rxWindowActive: true)),
          'Stopping 4s');
      expect(label(facts(isPendingDisable: true)), 'Stopping...');
      expect(label(facts(isTxModeRunning: true, isPingInProgress: true)),
          'Sending...');
      expect(label(facts(isTxModeRunning: true, discoveryWindowActive: true)),
          'Listening 6s');
    });

    test('the cooldown only shows on the button that caused it', () {
      expect(
          compactActiveModeLabel(facts(cooldownActive: true),
              showFullText: true, isExpandedDuringCooldown: false),
          isNull);
      expect(
          compactActiveModeLabel(facts(cooldownActive: true),
              showFullText: true, isExpandedDuringCooldown: true),
          'Cooldown 5s');
    });

    test('Trace can never say Deferred', () {
      // It hardcodes the skipped word instead of asking pausedWord. Safe only
      // because Smart Pinging does not defer a trace today.
      expect(
          compactTraceModeLabel(
              facts(
                  isTargetedRunning: true,
                  autoPingWaiting: true,
                  autoPingSkipReason: PingService.skipReasonRecentlyCovered),
              showFullText: true,
              isExpandedDuringCooldown: false),
          'Skipped 22s');
    });

    test('a running trace with nothing pending says Stop, or nothing', () {
      expect(
          compactTraceModeLabel(facts(isTargetedRunning: true),
              showFullText: true, isExpandedDuringCooldown: false),
          'Stop');
      // The only label that collapses to nothing rather than to a number.
      expect(
          compactTraceModeLabel(facts(isTargetedRunning: true),
              showFullText: false, isExpandedDuringCooldown: false),
          isNull);
    });
  });

  group('the Trace section', () {
    test('its status line', () {
      expect(traceStatusText(facts()), isNull);
      expect(
          traceStatusText(
              facts(isTargetedRunning: true, discoveryWindowActive: true)),
          'Listening 6s');
      expect(
          traceStatusText(
              facts(isTargetedRunning: true, autoPingWaiting: true)),
          'Next trace 22s');
      expect(
          traceStatusText(facts(
              isTargetedRunning: true,
              autoPingWaiting: true,
              autoPingSkipReason: PingService.skipReasonRecentlyCovered)),
          'Skipped 22s');
    });

    test('its button word', () {
      expect(traceSectionLabel(facts(), isStarting: false), 'Trace Mode');
      expect(traceSectionLabel(facts(), isStarting: true), 'Starting...');
      expect(traceSectionLabel(facts(cooldownActive: true), isStarting: false),
          'Cooldown 5s');
      expect(
          traceSectionLabel(facts(isTargetedRunning: true), isStarting: false),
          'Stop');
      expect(
          traceSectionLabel(
              facts(isTargetedRunning: true, discoveryWindowActive: true),
              isStarting: false),
          'Listening 6s');
    });

    test('starting outranks everything, including a running trace', () {
      expect(
          traceSectionLabel(facts(isTargetedRunning: true), isStarting: true),
          'Starting...');
    });
  });

  group('landscape, which shows numbers only', () {
    test('Send Ping shows nothing at all mid-send', () {
      expect(landscapeSendPingCountdown(facts(isPingSending: true)), isNull);
      expect(landscapeSendPingCountdown(facts(rxWindowActive: true)), 4);
      expect(landscapeSendPingCountdown(facts(manualCooldownActive: true)), 9);
      expect(landscapeSendPingCountdown(facts(cooldownActive: true)), 5);
      expect(landscapeSendPingCountdown(facts()), isNull);
    });

    test('an auto TX mode hides the manual listening number', () {
      expect(
          landscapeSendPingCountdown(
              facts(rxWindowActive: true, isTxModeRunning: true)),
          isNull);
    });

    test('Active/Hybrid, running and stopping', () {
      expect(
          landscapeActiveModeCountdown(
              facts(isTxModeRunning: true, discoveryWindowActive: true)),
          6);
      expect(
          landscapeActiveModeCountdown(
              facts(isTxModeRunning: true, autoPingWaiting: true)),
          22);
      expect(
          landscapeActiveModeCountdown(
              facts(isPendingDisable: true, rxWindowActive: true)),
          4);
      expect(
          landscapeActiveModeCountdown(facts(isPendingDisable: true)), isNull);
    });

    test('a deferred and a skipped ping are indistinguishable here', () {
      // No skip reason reaches this layout, so both read as a bare number.
      final deferred = facts(
          isTxModeRunning: true,
          autoPingWaiting: true,
          autoPingSkipReason: PingService.skipReasonRecentlyCovered);
      final skipped = facts(
          isTxModeRunning: true,
          autoPingWaiting: true,
          autoPingSkipReason: 'too close');
      expect(landscapeActiveModeCountdown(deferred),
          landscapeActiveModeCountdown(skipped));
    });

    test('Passive never shows the shared cooldown, unlike portrait', () {
      expect(
          landscapePassiveModeCountdown(facts(cooldownActive: true)), isNull);
      expect(
          portraitPassiveModeLabel(facts(cooldownActive: true)), 'Cooldown 5s');
      expect(
          landscapePassiveModeCountdown(
              facts(isPassiveModeRunning: true, autoPingWaiting: true)),
          22);
    });
  });

  group('the layouts agree on the waiting word', () {
    test('portrait and compact name the interval the same', () {
      // The wart B fixed: this used to read "Next ping" in portrait and
      // "Waiting" in compact, and "Next Disc" against "Waiting" for Passive.
      final tx = facts(isTxModeRunning: true, autoPingWaiting: true);
      expect(portraitActiveModeLabel(tx), 'Next ping 22s');
      expect(
          compactActiveModeLabel(tx,
              showFullText: true, isExpandedDuringCooldown: false),
          'Next ping 22s');

      final passive = facts(isPassiveModeRunning: true, autoPingWaiting: true);
      expect(portraitPassiveModeLabel(passive), 'Next disc 22s');
      expect(
          compactPassiveModeLabel(passive,
              showFullText: true, isExpandedDuringCooldown: false),
          'Next disc 22s');

      // Trace names its own action, but consistently across surfaces.
      expect(
          traceStatusText(
              facts(isTargetedRunning: true, autoPingWaiting: true)),
          'Next trace 22s');
    });
  });

  test('the paused word tells a hold apart from a drop', () {
    expect(pausedWord(PingService.skipReasonRecentlyCovered), 'Deferred');
    expect(pausedWord('too close'), 'Skipped');
    expect(pausedWord(null), 'Skipped');
  });
}
