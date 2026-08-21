/// What to do about offering an account link for the freshly connected radio.
enum LinkFlowDecision { skip, prompt }

/// Pure decision for the post-connection account-link offer.
///
/// Kept free of clocks, I/O and provider state so the whole truth table is
/// testable. The time-dependent parts (retry backoff, per-pubkey attempt cap)
/// stay in `AppStateProvider`, which checks them immediately before calling
/// this.
///
/// Linking is strictly non-fatal: EVERY uncertainty resolves to
/// [LinkFlowDecision.skip].
///
/// * [loggedIn] — a portal token is held.
/// * [offlineMode] / [anonymousMode] — user has opted out of identifying the
///   session; do not attach it to an account.
/// * [autoPingActive] — a wardrive is running (or is about to be restored after
///   a reconnect); never interrupt a drive with a modal.
/// * [autoReconnecting] — a BLE flap mid-drive must not re-prompt.
/// * [pubkey] — the radio's public key; null/empty means nothing to link.
/// * [declined] — the user said no for this pubkey and it was persisted.
/// * [linked] — the cache already has this pubkey bound to the account.
/// * [signUnsupported] — the firmware answered ERR to CMD_SIGN_START, or gave
///   repeated bad signatures. Re-prompting burns rate-limited nonces.
/// * [promptedThisAppSession] — asked once already since app launch. This is
///   per app session, NOT per connection, so a reconnect cannot re-ask.
LinkFlowDecision decideLinkFlow({
  required bool loggedIn,
  required bool offlineMode,
  required bool anonymousMode,
  required bool autoPingActive,
  required bool autoReconnecting,
  required String? pubkey,
  required bool declined,
  required bool linked,
  required bool signUnsupported,
  required bool promptedThisAppSession,
}) {
  if (!loggedIn) return LinkFlowDecision.skip;
  if (offlineMode) return LinkFlowDecision.skip;
  if (anonymousMode) return LinkFlowDecision.skip;
  if (autoPingActive) return LinkFlowDecision.skip;
  if (autoReconnecting) return LinkFlowDecision.skip;
  if (pubkey == null || pubkey.isEmpty) return LinkFlowDecision.skip;
  if (declined) return LinkFlowDecision.skip;
  if (linked) return LinkFlowDecision.skip;
  if (signUnsupported) return LinkFlowDecision.skip;
  if (promptedThisAppSession) return LinkFlowDecision.skip;
  return LinkFlowDecision.prompt;
}
