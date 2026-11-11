/// Whether nothing in the app would use a live API session right now.
///
/// Read by the scheduled keepalive when the server answers `session_expired`:
/// an idle app lets the session lapse instead of minting a replacement that
/// would never see a ping (an Android process frozen in the background after
/// a stopped mode, resumed later). Anything running, stopping, starting, in
/// flight, held open or waiting to upload counts as busy, and recovery then
/// runs exactly as before.
bool sessionIsIdle({
  required bool autoPingEnabled,
  required bool autoPingStarting,
  required bool pendingDisable,
  required bool pingSending,
  required bool pingInProgress,
  required bool repeaterAdminOpen,
  required int queuedItems,
}) =>
    !autoPingEnabled &&
    !autoPingStarting &&
    !pendingDisable &&
    !pingSending &&
    !pingInProgress &&
    !repeaterAdminOpen &&
    queuedItems == 0;
