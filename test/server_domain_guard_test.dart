import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Keeps the server's name in one place.
///
/// Every address the app builds comes from `ServerConfig`
/// (`lib/services/server_config.dart`), which is what lets a developer point
/// a build at another server. A file that writes the domain itself would
/// keep talking to live while the rest of the app is on a test server, so
/// this fails the moment one does.
void main() {
  // The accessor: the one line that may write the domain.
  const accessor = 'lib/services/server_config.dart';
  const accessorLine = "static const String liveDomain = 'meshmapper.net';";

  // Sentences shown to the user that NAME the site and are not addresses.
  // Each is listed with the exact text; a new one must be added here on
  // purpose.
  const sentences = <String, List<String>>{
    'lib/services/permission_disclosure_service.dart': [
      "'to meshmapper.net and shown on public coverage maps.',",
      "'With no mode running, your location is only sent to meshmapper.net to '",
    ],
  };

  final domain = RegExp(r'meshmapper\s*\.\s*net', caseSensitive: false);

  test('only ServerConfig writes the server domain under lib/', () {
    final offenders = <String>[];
    var accessorHits = 0;
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.endsWith('.g.dart'));

    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final line = lines[i];
        if (!domain.hasMatch(line)) continue;
        final text = line.trim();
        if (path == accessor && text == accessorLine) {
          accessorHits++;
          continue;
        }
        if (sentences[path]?.contains(text) ?? false) continue;
        offenders.add('$path:${i + 1}: $text');
      }
    }

    expect(accessorHits, 1,
        reason: 'ServerConfig.liveDomain must be the one default');
    expect(offenders, isEmpty,
        reason: 'The server domain is written outside ServerConfig. Build '
            'the address from ServerConfig instead:\n${offenders.join('\n')}');
  });

  test('the listed sentences still exist (drop stale entries)', () {
    sentences.forEach((path, texts) {
      final lines =
          File(path).readAsLinesSync().map((l) => l.trim()).toList();
      for (final text in texts) {
        expect(lines, contains(text), reason: '$path no longer has: $text');
      }
    });
  });
}
