import 'dart:async';

import '../../utils/debug_logger_io.dart';
import '../meshcore/connection.dart' show ContactRecord;
import 'scope_provider_support.dart';
import 'scope_runner.dart';

/// Companion firmware code (byte 1 of RESP_CODE_DEVICE_INFO) scope
/// discovery needs to ask a repeater at all.
const int kScopeDiscoveryFirmwareFloor = 13;

/// Everything the scope discovery gate reads.
///
/// [offered] is whether the last live `/auth` carried the `scope_discovery`
/// key, [enforced] whether it switched the feature on, [userEnabled] the
/// user's own switch, [firmwareCode] the connected companion's code.
typedef ScopeGateInputs = ({
  bool offered,
  bool enforced,
  bool userEnabled,
  bool offlineMode,
  int? firmwareCode,
});

/// Whether scope discovery may run: the server offered it, the effective
/// switch is on (the admin's enforcement wins over the user), Offline Mode
/// never asks, and the companion's firmware can carry the request.
bool scopeDiscoveryGateOpen(ScopeGateInputs g) =>
    g.offered &&
    (g.enforced || g.userEnabled) &&
    !g.offlineMode &&
    (g.firmwareCode ?? 0) >= kScopeDiscoveryFirmwareFloor;

/// The provider-side events that end scope work at once.
enum ScopeStopEvent {
  airborne('airborne'),
  offlineSwitch('offline mode switch'),
  onlineSwitch('online mode switch'),
  zoneTransfer('zone transfer'),
  userDisconnect('disconnect'),
  disconnectCleanup('disconnect cleanup'),
  autoReconnect('link lost'),
  gateClosed('scope discovery switched off'),
  dispose('disposed');

  /// The stop reason logged by the runner.
  final String reason;

  const ScopeStopEvent(this.reason);

  /// True when the connection goes with the event, so routes borrowed on
  /// it are forgotten too (the radio replaces them when it learns a path).
  bool get dropsConnection =>
      this == userDisconnect ||
      this == disconnectCleanup ||
      this == autoReconnect ||
      this == dispose;
}

/// The provider's scope discovery wiring in one testable place: whether a
/// sweep gets a runner, the Scopes badge, routes borrowed per connection,
/// the stop events, and the connect-time repeater refresh discard.
///
/// The Stop button and a force disable are handled inside PingService
/// itself (`disableAutoPing`, `forceDisableAutoPing`); this covers the
/// events that end a session without passing through there.
class ScopeLifecycle {
  final void Function(String reason) _cancelHostRunner;
  final void Function() _onBadgeChanged;

  bool _requestActive = false;
  ScopeRunner? _live;
  Object? _restoresOwner;
  final List<ContactRecord> _restores = [];
  final Set<String> _knownNonContacts = {};
  int _modeSwitches = 0;
  Timer? _repeaterRefreshTimer;

  /// [cancelHostRunner] cancels the runner PingService holds;
  /// [onBadgeChanged] is a plain notify (the badge is not on the map).
  ScopeLifecycle({
    required void Function(String reason) cancelHostRunner,
    required void Function() onBadgeChanged,
  })  : _cancelHostRunner = cancelHostRunner,
        _onBadgeChanged = onBadgeChanged;

  /// True while a scope request is out (the Scopes badge).
  bool get requestActive => _requestActive;

  /// The runner's `onActiveChanged`.
  void setRequestActive(bool active) {
    if (_requestActive == active) return;
    _requestActive = active;
    _onBadgeChanged();
  }

  /// The routes borrowed and not yet written back on [connection]. A
  /// different connection starts with none.
  List<ContactRecord> restoresFor(Object connection) {
    _syncConnectionScopeState(connection);
    return _restores;
  }

  /// The pubkeys this connection's own lookups already proved are not saved
  /// contacts. A different connection starts with none.
  Set<String> knownNonContactsFor(Object connection) {
    _syncConnectionScopeState(connection);
    return _knownNonContacts;
  }

  /// Resets every per-connection scope state ([_restores],
  /// [_knownNonContacts]) together the first time [connection] is seen,
  /// keyed on the same owner so neither can go stale relative to the other.
  void _syncConnectionScopeState(Object connection) {
    if (!identical(_restoresOwner, connection)) {
      _restores.clear();
      _knownNonContacts.clear();
      _restoresOwner = connection;
    }
  }

  /// One sweep's runner, or null when the gate is closed, an Offline Mode
  /// switch is in progress, there is no connection, or there is neither a
  /// device key nor a session id.
  /// [create] builds it with the device key and the connection's restores.
  ScopeRunner? buildRunner({
    required ScopeGateInputs gate,
    required Object? connection,
    required String? deviceKey,
    required ScopeRunner Function(String deviceKey,
            List<ContactRecord> pendingRestores, Set<String> knownNonContacts)
        create,
  }) {
    if (!scopeDiscoveryGateOpen(gate)) return null;
    if (modeSwitching) {
      debugLog('[SCOPES] No scope requests this sweep: a mode switch is '
          'in progress');
      return null;
    }
    if (connection == null || deviceKey == null) return null;
    final runner = create(
        deviceKey, restoresFor(connection), knownNonContactsFor(connection));
    _live = runner;
    return runner;
  }

  /// Ends any scope work at once for [event]: the runner PingService holds
  /// and the last one built here are cancelled (nothing more goes on the
  /// air for them), the badge clears, the periodic repeater refresh timer
  /// stops, and a lost connection takes its borrowed routes with it.
  void onEvent(ScopeStopEvent event) {
    _cancelHostRunner(event.reason);
    final live = _live;
    _live = null;
    live?.cancel(event.reason);
    setRequestActive(false);
    stopRepeaterRefreshTimer();
    if (event.dropsConnection) {
      _restores.clear();
      _knownNonContacts.clear();
      _restoresOwner = null;
    }
  }

  /// True while the periodic repeater-list refresh (Passive or Hybrid mode
  /// running) is scheduled.
  bool get repeaterRefreshTimerRunning => _repeaterRefreshTimer != null;

  /// (Re)starts the periodic repeater-list refresh: cancels any existing
  /// schedule first, so calling this again while one is already running
  /// reschedules it from now rather than stacking ticks. [onTick] fires
  /// every [period]; this scheduling is dumb on purpose, so the caller
  /// re-checks the gate, the zone and the radio preset itself on every
  /// tick, exactly as the connect-time refresh does.
  void startRepeaterRefreshTimer(Duration period, void Function() onTick) {
    _repeaterRefreshTimer?.cancel();
    _repeaterRefreshTimer = Timer.periodic(period, (_) => onTick());
  }

  /// Stops the periodic repeater-list refresh. Idempotent.
  void stopRepeaterRefreshTimer() {
    _repeaterRefreshTimer?.cancel();
    _repeaterRefreshTimer = null;
  }

  /// Starts an Offline Mode switch in either direction ([event] is
  /// [ScopeStopEvent.offlineSwitch] or [ScopeStopEvent.onlineSwitch]):
  /// ends any scope work at once, like [onEvent], and builds no runner until
  /// the matching [endModeSwitch]. Called on the switch's first line, before
  /// anything is awaited, because the gate still reads open while the switch
  /// waits (Offline Mode is only set at its end) and a discovery window
  /// closing then would otherwise start a fresh runner.
  void beginModeSwitch(ScopeStopEvent event) {
    _modeSwitches++;
    onEvent(event);
  }

  /// Ends a switch started by [beginModeSwitch]; runners are built again
  /// once every switch in progress has ended.
  void endModeSwitch() {
    if (_modeSwitches > 0) _modeSwitches--;
  }

  /// True while an Offline Mode switch is in progress.
  bool get modeSwitching => _modeSwitches > 0;

  /// Called whenever a gate input changes outside the stop events: a live
  /// `/auth` answer (a session recovery included) that drops or restores
  /// `scope_discovery`, or the user's own switch.
  ///
  /// A gate that is now closed stops the periodic repeater refresh timer
  /// (whether or not a request happens to be running) and cancels a live
  /// runner at once, so a lease mid-exchange writes nothing more (no
  /// borrow, no scope request).
  ///
  /// A gate that is now OPEN re-arms the periodic repeater refresh via
  /// [startRepeaterRefresh] (the same mode-start sequence, 5-minute stale
  /// check included) when [passiveOrHybridRunning] and no refresh is
  /// already scheduled: turning scope discovery off and back on again while
  /// Passive or Hybrid keeps running must not leave the refresh stopped for
  /// the rest of the session, only to be caught by the mode's own next
  /// start or stop. Already running (or the mode not running at all) is a
  /// no-op, so an unrelated gate check does not keep rescheduling it.
  void onGateChanged(
    ScopeGateInputs gate, {
    required bool passiveOrHybridRunning,
    required void Function() startRepeaterRefresh,
  }) {
    if (scopeDiscoveryGateOpen(gate)) {
      if (passiveOrHybridRunning && !repeaterRefreshTimerRunning) {
        debugLog('[SCOPES] Scope discovery switched back on with the mode '
            'still running: re-arming the periodic repeater refresh');
        startRepeaterRefresh();
      }
      return;
    }
    stopRepeaterRefreshTimer();
    final live = _live;
    if (live == null || live.isCancelled) return;
    debugLog('[SCOPES] Scope discovery switched off with a request running');
    onEvent(ScopeStopEvent.gateClosed);
  }

  /// Awaits [fetch] (started for [zone] under [preset]) and returns its
  /// result only when neither the zone nor the preset moved while it was in
  /// flight; null otherwise, and null when the fetch failed.
  Future<T?> resultIfStillCurrent<T>({
    required Future<T> fetch,
    required String zone,
    required String? preset,
    required String? Function() currentZone,
    required String? Function() currentPreset,
  }) async {
    final T result;
    try {
      result = await fetch;
    } catch (e) {
      debugWarn('[SCOPES] Repeater list refresh failed: $e');
      return null;
    }
    if (!scopeRepeaterRefreshStillCurrent(
        requestedZone: zone,
        requestedFilterKey: preset,
        currentZone: currentZone(),
        currentFilterKey: currentPreset())) {
      debugLog('[SCOPES] Repeater list for $zone discarded: the zone or '
          'preset changed while it loaded');
      return null;
    }
    return result;
  }
}
