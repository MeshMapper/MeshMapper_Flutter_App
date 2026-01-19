// Stub file for non-web platforms
// These functions are only available on web

/// Pick a file - not available on non-web platforms
void pickFileWeb({
  required String accept,
  required void Function(String content, String filename) onFilePicked,
}) {
  throw UnsupportedError('pickFileWeb is only available on web platform');
}

/// Download a file - not available on non-web platforms
void downloadFileWeb({
  required String content,
  required String filename,
  String mimeType = 'application/json',
}) {
  throw UnsupportedError('downloadFileWeb is only available on web platform');
}

/// Check if web file helpers are available
bool get isWebFileHelpersAvailable => false;
