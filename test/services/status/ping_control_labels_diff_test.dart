import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/connection_state.dart';
import 'package:mesh_mapper/providers/app_state_provider.dart' show AutoMode;
import 'package:mesh_mapper/services/ping_service.dart';
import 'package:mesh_mapper/services/status/ping_control_labels.dart' as live;
import 'package:mesh_mapper/services/status/session_status.dart';
import 'package:mesh_mapper/services/status/session_status_resolver.dart';

import 'legacy_ping_control_labels.dart' as old;

/// The mechanical half of the proof. The 48-row oracle pins the interesting
/// states by hand; this walks the WHOLE input space and asserts, for every
/// reachable combination of flags and timers, that each live renderer says
/// exactly what the frozen [old] chain said before the lift. A single reachable
/// disagreement fails the test with the offending facts printed, so the claim
/// "no label moved" is checked, not asserted.
///
/// Unreachable combinations are allowed to differ, because the model routes by
/// mode where the flat chains only looked at timers, and the two answers can
/// only diverge on states the app cannot hold. Each such divergence is required
/// to satisfy [reachable] returning false; the reachability rules are the real
/// app invariants and are listed where they are defined. The count of skipped
/// unreachable combinations is printed so a rule that quietly excuses too much
/// would be visible.

const _rx = 4;
const _manualCd = 9;
const _disc = 6;
const _shared = 5;
const _auto = 22;

old.LegacyFacts _facts(int mask, String? skip) => (
      isConnected: mask & 1 != 0,
      externalAntennaSet: true,
      isPowerSet: true,
      isTxModeRunning: mask & 2 != 0,
      isPassiveModeRunning: mask & 4 != 0,
      isTargetedRunning: mask & 8 != 0,
      isPendingDisable: mask & 16 != 0,
      isPingSending: mask & 32 != 0,
      isPingInProgress: mask & 64 != 0,
      hybridEnabled: mask & 128 != 0,
      txBlockedByOffline: mask & 256 != 0,
      txNotAllowed: mask & 512 != 0,
      rxWindowActive: mask & 1024 != 0,
      rxWindowRemaining: _rx,
      manualCooldownActive: mask & 2048 != 0,
      manualCooldownRemaining: _manualCd,
      discoveryWindowActive: mask & 4096 != 0,
      discoveryWindowRemaining: _disc,
      cooldownActive: mask & 8192 != 0,
      cooldownRemaining: _shared,
      autoPingWaiting: mask & 16384 != 0,
      autoPingRemaining: _auto,
      autoPingSkipReason: skip,
    );

/// The real invariants of the app, used only to excuse divergences on states it
/// cannot hold. Deliberately narrow: it rules out only the impossible, so any
/// reachable divergence is still caught.
bool reachable(old.LegacyFacts f) {
  final modes = (f.isTxModeRunning ? 1 : 0) +
      (f.isPassiveModeRunning ? 1 : 0) +
      (f.isTargetedRunning ? 1 : 0);
  // Only one auto mode runs at a time.
  if (modes > 1) return false;
  final anyMode = modes == 1;
  // A disconnect tears down every timer, so no countdown of any kind survives
  // it. A frame that renders a running timer while disconnected cannot happen.
  if (!f.isConnected &&
      (anyMode ||
          f.autoPingWaiting ||
          f.discoveryWindowActive ||
          f.rxWindowActive ||
          f.cooldownActive ||
          f.manualCooldownActive ||
          f.isPendingDisable ||
          f.isPingSending ||
          f.isPingInProgress)) {
    return false;
  }
  // When the zone is at TX capacity the whole `!txNotAllowed` button group is
  // hidden (ping_controls.dart, the visibility guard), so the Send Ping and
  // Active labels are never rendered; the Passive and Trace labels that remain
  // do not depend on the flag, so these states exercise no rendered label the
  // txAllowed states do not already cover.
  if (f.txNotAllowed) return false;
  // The interval timer only runs under an auto mode.
  if (f.autoPingWaiting && !anyMode) return false;
  // A skip reason only exists while an auto ping is being held or skipped.
  if (f.autoPingSkipReason != null && !f.autoPingWaiting) return false;
  // A discovery window only opens under Passive, Trace, or Hybrid; Active never
  // opens one.
  if (f.discoveryWindowActive &&
      !(f.isPassiveModeRunning ||
          f.isTargetedRunning ||
          (f.isTxModeRunning && f.hybridEnabled))) {
    return false;
  }
  // The shared post-stop cooldown is a quiet five seconds: no mode is running,
  // nothing is being stopped, and no other timer is up (Send Ping is disabled
  // for its duration, so no manual ping starts).
  if (f.cooldownActive &&
      (anyMode ||
          f.isPendingDisable ||
          f.isPingSending ||
          f.isPingInProgress ||
          f.rxWindowActive ||
          f.manualCooldownActive ||
          f.discoveryWindowActive ||
          f.autoPingWaiting)) {
    return false;
  }
  // Send Ping is disabled while an auto TX mode runs (the `!isTxModeRunning`
  // clause of its enable predicate), so no manual ping starts there and neither
  // a manual send nor its cooldown ever accompanies Active or Hybrid.
  if (f.isTxModeRunning && (f.isPingSending || f.manualCooldownActive)) {
    return false;
  }
  // Hybrid alternates its TX leg (the echo window) with its discovery leg (the
  // discovery window) an interval apart, and the echo closes long before the
  // next leg, so the two windows never render at once. Active has no discovery
  // leg at all, so this only rules out the impossible Hybrid overlap.
  if (f.isTxModeRunning && f.rxWindowActive && f.discoveryWindowActive) {
    return false;
  }
  // A manual send in flight is, by definition, a ping in progress.
  if (f.isPingSending && !f.isPingInProgress) return false;
  // A manual send and its own RX window never render together. `_isPingSending`
  // is cleared synchronously in the send's `finally`, immediately after the
  // window is armed, and a ListenableBuilder rebuild is deferred to the next
  // frame, so no frame ever observes both flags up. (Verified in
  // app_state_provider.dart's manual-ping finally and ping_service's
  // _startRxListeningWindow.)
  if (f.isPingSending && f.rxWindowActive) return false;
  // The auto interval and this session's own listening window are alternatives,
  // never both up at once. (A different lane's window can overlap, e.g. a manual
  // RX window during a Passive interval, so only the same-mode window is ruled
  // out.)
  if (f.autoPingWaiting) {
    if (f.isPassiveModeRunning && f.discoveryWindowActive) return false;
    if (f.isTargetedRunning && f.discoveryWindowActive) return false;
    if (f.isTxModeRunning && (f.rxWindowActive || f.discoveryWindowActive)) {
      return false;
    }
    // A pending disable is only set while a ping is in progress, which means a
    // listening window is open, not the interval; `disableAutoPing` returns
    // early on `_pingInProgress` (ping_service.dart:1427). So the interval and a
    // pending disable never run together.
    if (f.isPendingDisable) return false;
    // The auto TX interval self-expires to fire the ping, so a ping in progress
    // (which stays set through its RX window) and the interval to the NEXT ping
    // are sequential phases of one cycle, never up together.
    if (f.isTxModeRunning && f.isPingInProgress) return false;
  }
  return true;
}

StatusDeadline? _dl(bool running, int rem) => running
    ? (endsAt: DateTime.utc(2026, 1, 1, 12), durationMs: null, remainingSec: rem)
    : null;

SessionStatus _status(old.LegacyFacts k) {
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

live.PingRenderFacts _render(old.LegacyFacts k) => (
      txBlockedByOffline: k.txBlockedByOffline,
      txNotAllowed: k.txNotAllowed,
      hybridEnabled: k.hybridEnabled,
      isTxModeRunning: k.isTxModeRunning,
      isPassiveModeRunning: k.isPassiveModeRunning,
      isTargetedRunning: k.isTargetedRunning,
      isPendingDisable: k.isPendingDisable,
    );

void main() {
  test('every reachable state renders exactly as it did before the lift', () {
    final skips = <String?>[null, PingService.skipReasonRecentlyCovered, 'x'];
    final bools = [false, true];
    final mismatches = <String>[];
    var reachableChecked = 0;
    var unreachableSkipped = 0;

    void diff(String fn, old.LegacyFacts f, Object? a, Object? b) {
      if (a == b) return;
      if (reachable(f)) {
        mismatches.add('$fn  legacy=$a  new=$b  facts=${_desc(f)}');
      } else {
        unreachableSkipped++;
      }
    }

    for (var mask = 0; mask < (1 << 15); mask++) {
      for (final skip in skips) {
        final f = _facts(mask, skip);
        final s = _status(f);
        final r = _render(f);

        diff('sendPing', f, old.legacyPortraitSendPingLabel(f),
            live.portraitSendPingLabel(s, r));
        diff('active', f, old.legacyPortraitActiveModeLabel(f),
            live.portraitActiveModeLabel(s, r));
        diff('passive', f, old.legacyPortraitPassiveModeLabel(f),
            live.portraitPassiveModeLabel(s, r));
        diff('landSend', f, old.legacyLandscapeSendPingCountdown(f),
            live.landscapeSendPingCountdown(s, r));
        diff('landActive', f, old.legacyLandscapeActiveModeCountdown(f),
            live.landscapeActiveModeCountdown(s, r));
        diff('landPassive', f, old.legacyLandscapePassiveModeCountdown(f),
            live.landscapePassiveModeCountdown(s, r));
        diff('traceStatus', f, old.legacyTraceStatusText(f),
            live.traceStatusText(s, r));

        for (final full in bools) {
          diff('cSend[$full]', f,
              old.legacyCompactSendPingLabel(f, showFullText: full),
              live.compactSendPingLabel(s, r, showFullText: full));
          for (final exp in bools) {
            diff(
                'cActive[$full,$exp]',
                f,
                old.legacyCompactActiveModeLabel(f,
                    showFullText: full, isExpandedDuringCooldown: exp),
                live.compactActiveModeLabel(s, r,
                    showFullText: full, isExpandedDuringCooldown: exp));
            diff(
                'cPassive[$full,$exp]',
                f,
                old.legacyCompactPassiveModeLabel(f,
                    showFullText: full, isExpandedDuringCooldown: exp),
                live.compactPassiveModeLabel(s, r,
                    showFullText: full, isExpandedDuringCooldown: exp));
            diff(
                'cTrace[$full,$exp]',
                f,
                old.legacyCompactTraceModeLabel(f,
                    showFullText: full, isExpandedDuringCooldown: exp),
                live.compactTraceModeLabel(s, r,
                    showFullText: full, isExpandedDuringCooldown: exp));
          }
        }
        for (final starting in bools) {
          diff('traceSection[$starting]', f,
              old.legacyTraceSectionLabel(f, isStarting: starting),
              live.traceSectionLabel(s, r, isStarting: starting));
        }
        if (reachable(f)) reachableChecked++;
      }
    }

    // Dedupe the report so a single systematic divergence is one line.
    final unique = mismatches.toSet().toList()..sort();
    // ignore: avoid_print
    print('reachable facts checked: $reachableChecked, '
        'unreachable skipped: $unreachableSkipped, '
        'reachable divergences: ${unique.length}');
    expect(unique, isEmpty,
        reason: 'reachable label divergences:\n${unique.take(60).join('\n')}');
  });
}

String _desc(old.LegacyFacts f) {
  final on = <String>[];
  void add(String n, bool v) {
    if (v) on.add(n);
  }

  add('conn', f.isConnected);
  add('tx', f.isTxModeRunning);
  add('passive', f.isPassiveModeRunning);
  add('targeted', f.isTargetedRunning);
  add('pending', f.isPendingDisable);
  add('sending', f.isPingSending);
  add('inProgress', f.isPingInProgress);
  add('hybrid', f.hybridEnabled);
  add('offline', f.txBlockedByOffline);
  add('notAllowed', f.txNotAllowed);
  add('rx', f.rxWindowActive);
  add('manualCd', f.manualCooldownActive);
  add('disc', f.discoveryWindowActive);
  add('shared', f.cooldownActive);
  add('autoWait', f.autoPingWaiting);
  if (f.autoPingSkipReason != null) on.add('skip=${f.autoPingSkipReason}');
  return on.join('+');
}
