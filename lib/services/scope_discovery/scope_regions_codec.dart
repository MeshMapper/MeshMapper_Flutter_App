import 'dart:convert';
import 'dart:typed_data';
import '../meshcore/protocol_constants.dart';

/// A repeater holds at most 32 regions, plus `*`.
const int kMaxScopeEntries = 33;

/// `[regions][reply path len 0]`: the repeater answers zero-hop direct.
Uint8List buildRegionsRequest() =>
    Uint8List.fromList([AnonRequestTypes.regions, 0x00]);

/// Parses the body of a regions reply as the connection hands it over
/// (tag already removed): `[repeater clock 4][comma-separated names]`.
/// Returns null for a malformed answer, which the caller logs and never
/// uploads. Names are kept exactly as sent: scope names are
/// case-sensitive in firmware, so nothing is trimmed or lower-cased.
/// Byte-faithful: splits at 0x2C (comma), validates each segment's bytes,
/// decodes, and preserves any leading byte-order mark (BOM, U+FEFF).
///
/// The reply travels AES encrypted in 16-byte blocks and the companion
/// hands over whole blocks, so the names are followed by zero padding.
/// Trailing zeros are dropped; a zero anywhere before them is malformed.
List<String>? parseRegionsReply(Uint8List data) {
  if (data.length < 4) return null;
  var end = data.length;
  while (end > 4 && data[end - 1] == 0) {
    end--;
  }
  final body = data.sublist(4, end);
  if (body.isEmpty) return const <String>[];
  if (body.contains(0)) return null;

  // Split at byte level on 0x2C (comma)
  final segments = <Uint8List>[];
  int start = 0;
  for (int i = 0; i < body.length; i++) {
    if (body[i] == 0x2C) {
      segments.add(body.sublist(start, i));
      start = i + 1;
    }
  }
  segments.add(body.sublist(start));

  if (segments.length > kMaxScopeEntries) return null;

  // Validate and decode each segment
  final names = <String>[];
  for (final segment in segments) {
    if (!_isValidScopeTokenBytes(segment)) return null;
    final String name;
    try {
      // Decode segment; this may drop a leading BOM
      name = utf8.decode(segment);
    } on FormatException {
      return null;
    }
    // If segment starts with BOM (EF BB BF), restore it
    if (segment.length >= 3 &&
        segment[0] == 0xEF &&
        segment[1] == 0xBB &&
        segment[2] == 0xBF) {
      names.add('\u{FEFF}$name');
    } else {
      names.add(name);
    }
  }
  return names;
}

/// Validates a scope token at the byte level: exactly [0x2A] (`*`), or
/// 1 to 30 bytes with no leading 0x23 (#), every byte one of 0x2D (-),
/// 0x24 ($), 0x23 (#), 0x30-0x39 (0-9), or >= 0x41 (A).
bool _isValidScopeTokenBytes(Uint8List bytes) {
  if (bytes.length == 1 && bytes[0] == 0x2A) return true; // exactly '*'
  if (bytes.isEmpty || bytes.length > 30) return false;
  if (bytes[0] == 0x23) return false; // leading '#'
  for (final b in bytes) {
    final ok = b == 0x2D || b == 0x24 || b == 0x23 ||
        (b >= 0x30 && b <= 0x39) || b >= 0x41;
    if (!ok) return false;
  }
  return true;
}

/// The server's (and firmware's) token rule for one scope name: exactly
/// `*`, or 1 to 30 bytes with no leading `#`, every byte one of `-`, `$`,
/// `#`, `0`-`9`, or at least `A`. The server rejects a whole SCOPES item
/// for one bad entry.
bool isValidScopeToken(String name) {
  if (name == '*') return true;
  final bytes = utf8.encode(name);
  if (bytes.isEmpty || bytes.length > 30) return false;
  if (bytes.first == 0x23) return false; // leading '#'
  for (final b in bytes) {
    final ok = b == 0x2D || b == 0x24 || b == 0x23 ||
        (b >= 0x30 && b <= 0x39) || b >= 0x41;
    if (!ok) return false;
  }
  return true;
}
