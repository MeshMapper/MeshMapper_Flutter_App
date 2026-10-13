/// What a `session_expired` answer should do when it arrives while a
/// replacement session may already be under way.
enum SessionRecoveryJoin {
  /// A recovery is running: hand its future back, the caller waits on it.
  joinInFlight,

  /// A group handoff owns the recovery slot. Its drain uploads under the old
  /// session, and that upload is the lane asking; handing it the handoff's
  /// own future would make the two wait on each other for good. Answer
  /// `superseded` at once: the upload comes back held (no retry spent), the
  /// keepalive and the preflight bow out, and the handoff mints the
  /// replacement itself.
  supersededByHandoff,

  /// Nothing is running: start a recovery.
  startNew,
}

/// Pure rule behind `AppStateProvider._recoverExpiredLiveSession`. The
/// handoff test comes first: while it holds the slot, the in-flight future IS
/// the handoff, so a joiner must never be handed it.
SessionRecoveryJoin resolveSessionRecoveryJoin({
  required bool groupHandoffOwnsSlot,
  required bool recoveryInFlight,
}) {
  if (groupHandoffOwnsSlot) return SessionRecoveryJoin.supersededByHandoff;
  if (recoveryInFlight) return SessionRecoveryJoin.joinInFlight;
  return SessionRecoveryJoin.startNew;
}
