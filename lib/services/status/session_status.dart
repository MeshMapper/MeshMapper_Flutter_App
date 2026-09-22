/// Shared session status types.
///
/// One derivation, read by every surface. Before this, the in-app buttons, the
/// phase the Live Activity / watch / Siri read, and the Android notification
/// each worked out what the session was doing on their own, which is why they
/// could disagree rather than merely lag.
library;

import '../live_activity/live_activity_models.dart';

/// The ping lifecycle step a session is in, latched at the moment the radio is
/// asked to transmit and cleared when the next interval is scheduled.
///
/// Deliberately platform neutral. This began life inside the provider as a
/// Live Activity detail and was only ever latched on iOS, which quietly made
/// the shared phase resolver a description of an iOS session rather than of the
/// app: on Android the branches that read it were unreachable. Every surface
/// reads the same session now, so the fact is recorded everywhere and it is the
/// Live Activity's own consumer that decides whether an activity exists.
enum SessionOperation { sending, discovering, tracing }

/// Which of the four things a session can be doing owns the current moment.
///
/// The in-app UI shows all four at once, each with its own word, while the
/// glance surfaces show one. That difference is entirely a question of
/// ownership: the identical fact "an RX window is running" reads "Listening" on
/// the button that owns the window and "Cooldown" on the two beside it.
enum StatusLane {
  /// A single ping the user tapped.
  manual,

  /// Active or Hybrid: the auto TX loop.
  txAuto,

  /// Passive: discovery requests.
  discovery,

  /// Trace: zero-hop path to one repeater.
  targeted,
}

/// When something ends, how long it ran, and how many seconds a button should
/// print beside it.
///
/// The duration travels with the deadline rather than being recovered later by
/// matching a timestamp against every live timer, which is what the provider
/// used to do. A null duration means no timer owns it: today only the zone
/// grace deadline, which is a wall-clock instant rather than a countdown.
///
/// [remainingSec] is here rather than computed from [endsAt] so the number a
/// button prints is the exact one its timer reports, rounded the same way, and
/// so nothing in this layer needs a clock. It moves every tick; [endsAt] does
/// not, which is what the glance surfaces throttle on.
typedef StatusDeadline = ({DateTime endsAt, int? durationMs, int remainingSec});

/// One lane's view of the session.
typedef LaneStatus = ({
  SessionActivity activity,
  StatusDeadline? deadline,

  /// True when this lane is not the one acting: the activity and deadline
  /// describe what is holding it up rather than what it is doing.
  bool isBlocked,
});

/// The whole session, resolved once.
///
/// [activity], [owner] and [deadline] are the single-phase answer the Live
/// Activity, the watch and Siri read. The four lanes are the same instant seen
/// from each button. Both come out of one ordered list of observations, so a
/// surface cannot claim a state no lane is in.
///
/// A record, so equality is structural and free. It carries no validator
/// result on purpose: reading one runs a full `canPing()` pass including a
/// distance calculation and a coverage lookup, and this is resolved on every
/// countdown tick. Refusals stay with the three validators that own them and
/// are passed to the renderers that want them.
typedef SessionStatus = ({
  SessionActivity activity,
  StatusLane? owner,
  StatusDeadline? deadline,
  LaneStatus manual,
  LaneStatus txAuto,
  LaneStatus discovery,
  LaneStatus targeted,
});

extension SessionStatusLanes on SessionStatus {
  /// This lane's view of the session.
  LaneStatus lane(StatusLane which) => switch (which) {
        StatusLane.manual => manual,
        StatusLane.txAuto => txAuto,
        StatusLane.discovery => discovery,
        StatusLane.targeted => targeted,
      };
}

/// The canonical name of a state.
///
/// Named for the session rather than for the Live Activity, which was only its
/// first consumer. The old name stays as an alias so no caller and no wire
/// value moves.
typedef SessionActivity = LiveActivityPhase;
