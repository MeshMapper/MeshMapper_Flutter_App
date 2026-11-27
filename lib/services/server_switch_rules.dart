import 'server_config.dart';

/// Why the server cannot be changed right now, or null when it can.
///
/// A change of server is refused while anything of the current server is
/// still in flight: a wardrive session, pings waiting to upload, an upload
/// in progress, or an offline drive not yet saved. Saved offline drives do
/// not count: each names the server it was recorded on and only ever
/// uploads there.
String? serverSwitchBlockReason({
  required bool radioConnected,
  required bool connecting,
  required bool sessionActive,
  required int queuedUploads,
  required bool uploading,
  required int unsavedOfflinePings,
}) {
  if (sessionActive) {
    return 'A wardrive session is active. Disconnect before changing the '
        'server.';
  }
  if (radioConnected || connecting) {
    return 'A radio is connected. Disconnect before changing the server.';
  }
  if (uploading) {
    return 'An upload is in progress. Wait for it to finish before changing '
        'the server.';
  }
  if (queuedUploads > 0) {
    final pings = queuedUploads == 1 ? '1 ping is' : '$queuedUploads pings are';
    return '$pings still waiting to upload. Let the upload finish before '
        'changing the server.';
  }
  if (unsavedOfflinePings > 0) {
    return 'An offline drive is still being recorded. Disconnect to save it '
        'before changing the server.';
  }
  return null;
}

/// What the user is told when the server refuses the app key (`bad_key`).
/// On the dev server the key is one the developer typed, so the message
/// names the server it was refused by.
String badKeyMessage() => ServerConfig.isDev
    ? 'This key is not valid on ${ServerConfig.baseDomain}.'
    : 'Invalid API key. Please check configuration.';
