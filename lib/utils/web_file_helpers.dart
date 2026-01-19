// Web-specific file helpers
// This file is only imported on web platform

import 'dart:js_interop';
import 'package:web/web.dart' as web;

/// Pick a file on web platform
void pickFileWeb({
  required String accept,
  required void Function(String content, String filename) onFilePicked,
}) {
  final input = web.document.createElement('input') as web.HTMLInputElement;
  input.type = 'file';
  input.accept = accept;

  input.onChange.listen((event) {
    final files = input.files;
    if (files != null && files.length > 0) {
      final file = files.item(0);
      if (file != null) {
        final reader = web.FileReader();

        reader.onLoadEnd.listen((event) {
          final result = reader.result;
          if (result != null) {
            final content = result.toString();
            onFilePicked(content, file.name);
          }
        });

        reader.readAsText(file);
      }
    }
  });

  input.click();
}

/// Download a file on web platform
void downloadFileWeb({
  required String content,
  required String filename,
  String mimeType = 'application/json',
}) {
  final blob = web.Blob(
    [content.toJS].toJS,
    web.BlobPropertyBag(type: mimeType),
  );
  final url = web.URL.createObjectURL(blob);
  final anchor = web.document.createElement('a') as web.HTMLAnchorElement;
  anchor.href = url;
  anchor.download = filename;
  anchor.click();
  web.URL.revokeObjectURL(url);
}

/// Check if web file helpers are available
bool get isWebFileHelpersAvailable => true;
