/// Full MeshCore public key handling for the shared CARpeater list.
///
/// A key is 32 bytes, so exactly 64 hex characters. The normalized form is
/// upper case with no prefix, the same convention the server uses
/// (`heard_normalize_key` strips `!` and `0x` and upper-cases).
library;

final RegExp _fullKey = RegExp(r'^[0-9A-F]{64}$');

/// The upper-case 64-hex form of [raw], or null when it is not a full key.
/// Leading and trailing whitespace and a `0x` or `!` prefix are tolerated.
String? normalizePublicKey(String? raw) {
  if (raw == null) return null;
  var s = raw.trim().toUpperCase();
  if (s.startsWith('0X')) s = s.substring(2);
  if (s.startsWith('!')) s = s.substring(1);
  return _fullKey.hasMatch(s) ? s : null;
}

/// True when [raw] normalizes to a full key.
bool isFullPublicKey(String? raw) => normalizePublicKey(raw) != null;
