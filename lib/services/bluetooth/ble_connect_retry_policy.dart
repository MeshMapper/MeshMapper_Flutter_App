/// Pure retry-policy decisions for BLE connection failures (#500).
///
/// connect() used to retry only Android error 133, so the 15s GATT connect
/// timeout, transient GATT errors and service discovery failures all gave up
/// on attempt 1 of 3, and users re-tapped Connect to do the loop's work.
/// These decisions are pure functions so the policy is unit-testable without
/// flutter_blue_plus.
library;

/// What connect() should do with a failed attempt.
enum BleConnectFailureAction {
  /// Transient failure: clean up and run the next attempt.
  retry,

  /// iOS stale-bond error (apple-code 14/15). Internal retries all fail the
  /// same way and each hangs for the full connect timeout, so abort now and
  /// let the auto-reconnect system apply a longer delay.
  abortForBondError,

  /// Attempts exhausted: surface the error to the caller.
  fail,
}

/// Decide how connect() handles a failed attempt.
///
/// Every failure is retryable while attempts remain, except iOS bond errors
/// which abort immediately (stale keys cannot be cleared programmatically).
BleConnectFailureAction classifyBleConnectFailure({
  required String errorString,
  required bool isIos,
  required int attempt,
  required int maxRetries,
}) {
  final isBondError = isIos &&
      (errorString.contains('apple-code: 14') ||
          errorString.contains('apple-code: 15') ||
          errorString.contains('Peer removed pairing information'));
  if (isBondError) {
    return BleConnectFailureAction.abortForBondError;
  }
  if (attempt < maxRetries) {
    return BleConnectFailureAction.retry;
  }
  return BleConnectFailureAction.fail;
}

/// How soon after a successful transport connect a workflow death still counts
/// as "the link died right after connecting". 20s covers a single 15s
/// writeCharacteristic timeout on the first protocol command.
const Duration handshakeRerunWindow = Duration(seconds: 20);

/// Decide whether connectToDevice() re-runs the 9-step connection workflow
/// after it died shortly after a successful transport connect.
///
/// Deliberately excluded:
/// - server auth verdicts (AUTH_FAILED:) are deterministic, a re-run just
///   hits the server again with the same answer;
/// - auto-reconnect already re-runs the whole workflow per attempt;
/// - a disposed connection means something else tore the attempt down.
bool shouldRerunConnectionWorkflow({
  required bool transportConnected,
  required Duration? sinceTransportConnect,
  required String errorString,
  required bool isAutoReconnecting,
  required bool userRequestedDisconnect,
  required bool alreadyRerun,
}) {
  if (alreadyRerun || isAutoReconnecting || userRequestedDisconnect) {
    return false;
  }
  if (!transportConnected || sinceTransportConnect == null) {
    return false;
  }
  if (sinceTransportConnect > handshakeRerunWindow) {
    return false;
  }
  if (errorString.contains('AUTH_FAILED:')) {
    return false;
  }
  if (errorString.contains('has been disposed')) {
    return false;
  }
  return true;
}
