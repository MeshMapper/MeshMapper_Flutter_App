import 'dart:math' as math;

import '../models/repeater.dart';

/// Resolves a heard repeater id that arrived narrower than the repeater's own
/// width to the one known repeater it can only mean.
///
/// A packet carries its hop ids at the width its sender chose, 1, 2 or 3
/// bytes, so in a 3-byte region an advert relayed with 1-byte ids names
/// repeater `A81EA4` as just `A8`. Matched at full length only, that showed as
/// a second, unnamed repeater beside the real one.
///
/// The rule is the server's (`rc_resolve_token` in the server's
/// `repeater_collision.php`): a repeater's key is its cleaned hex id, else its
/// legacy id; it matches when the key starts with the heard id, case
/// ignored. Matches whose keys form one prefix chain are the same device (a
/// legacy short row plus the full-key row) and collapse to the longest key.
/// Anything else is ambiguous and resolves to nothing, because a confidently
/// wrong repeater is worse than a bare id.
///
/// Used for display (Top Heard) and for reading stored coverage (the cell
/// summary and repeater stats, through `RepeaterLookup`). Logs and uploads
/// keep the raw heard id, and the server resolves it again on its own.
///
/// The region's path width never takes part in matching: an id is judged at
/// its own width only, so the same stored ping reads the same in any region.
///
/// Built once per repeater list (the provider caches it on the list's
/// identity): ids of 1, 2 and 3 bytes, the only widths a path carries, are
/// answered from a prefix map, and any other length falls back to a scan.
class ShortHopIds {
  static const List<int> _indexedLengths = [2, 4, 6];

  final List<_Slot> _keys;
  final Map<String, _Slot> _byPrefix;
  final Map<String, List<_Slot>> _byFirstByte;

  ShortHopIds._(this._keys, this._byPrefix, this._byFirstByte);

  factory ShortHopIds.fromRepeaters(Iterable<Repeater> repeaters) {
    final keys = <_Slot>[];
    final byPrefix = <String, _Slot>{};
    final byFirstByte = <String, List<_Slot>>{};
    for (final repeater in repeaters) {
      final key = _clean(repeater.hexId) ?? _clean(repeater.id);
      if (key == null) continue;
      final slot = _Slot(key, repeater);
      keys.add(slot);
      (byFirstByte[key.substring(0, 2)] ??= <_Slot>[]).add(slot);
      for (final length in _indexedLengths) {
        if (key.length < length) break;
        final prefix = key.substring(0, length);
        final existing = byPrefix[prefix];
        byPrefix[prefix] = existing == null ? slot : existing.merge(slot);
      }
    }
    return ShortHopIds._(keys, byPrefix, byFirstByte);
  }

  /// The one repeater [heardId] can mean, or null when none or several do.
  Repeater? resolve(String heardId) => _slotFor(heardId)?.repeater;

  /// Every repeater row whose key starts with [heardId], in list order. Empty
  /// when the id is unknown, more than one row when it is ambiguous or one
  /// device has several rows. For callers that settle an ambiguous id with
  /// other evidence, such as the coordinates stamped on a stored hop.
  List<Repeater> matching(String heardId) {
    final token = _clean(heardId);
    if (token == null) return const <Repeater>[];
    final bucket = _byFirstByte[token.substring(0, 2)];
    if (bucket == null) return const <Repeater>[];
    return [
      for (final slot in bucket)
        if (slot.key.startsWith(token)) slot.repeater,
    ];
  }

  /// [heardId] as Top Heard shows and groups it: when it resolves, the
  /// repeater's key cut to the wider of its own advertised width and the
  /// region's [hopBytes] (never narrower than [heardId]), so `A8` and
  /// `A81EA4` become the same row. Otherwise [heardId] unchanged. Upper case
  /// either way.
  String displayId(String heardId, {required int hopBytes}) {
    final slot = _slotFor(heardId);
    if (slot == null) return heardId.toUpperCase();
    final width = math.max(
        heardId.length, math.max(slot.repeater.advertBytes, hopBytes) * 2);
    return slot.key
        .substring(0, math.min(width, slot.key.length))
        .toUpperCase();
  }

  /// One entry per repeater heard in [rows], keyed by [displayId], holding the
  /// best SNR among the ids that resolve to it.
  Map<String, double> bestSnrByRepeater(
    Iterable<({String repeaterId, double snr})> rows, {
    required int hopBytes,
  }) {
    final best = <String, double>{};
    for (final row in rows) {
      final key = displayId(row.repeaterId, hopBytes: hopBytes);
      final existing = best[key];
      if (existing == null || row.snr > existing) best[key] = row.snr;
    }
    return best;
  }

  _Slot? _slotFor(String heardId) {
    final token = _clean(heardId);
    if (token == null) return null;
    _Slot? found;
    if (_indexedLengths.contains(token.length)) {
      found = _byPrefix[token];
    } else {
      for (final slot in _keys) {
        if (!slot.key.startsWith(token)) continue;
        found = found == null ? slot : found.merge(slot);
      }
    }
    return found == null || found.ambiguous ? null : found;
  }

  /// Cleaned lower-case hex of at least one byte, or null.
  static String? _clean(String value) {
    final clean = value
        .replaceAll('!', '')
        .replaceAll(RegExp('0x', caseSensitive: false), '')
        .toLowerCase();
    if (clean.length < 2 || !_hex.hasMatch(clean)) return null;
    return clean;
  }

  static final RegExp _hex = RegExp(r'^[a-f0-9]+$');
}

/// The longest key seen under one prefix, or the marker that two keys under
/// it are different devices.
class _Slot {
  final String key;
  final Repeater? _repeater;

  const _Slot(this.key, Repeater this._repeater);
  const _Slot._none()
      : key = '',
        _repeater = null;

  static const _Slot _conflict = _Slot._none();

  bool get ambiguous => _repeater == null;

  /// Only read on a slot that is not [ambiguous].
  Repeater get repeater => _repeater!;

  /// Every key in a chain is a prefix of its longest, so comparing a new key
  /// with the longest so far decides whether it is the same device.
  _Slot merge(_Slot other) {
    if (ambiguous) return this;
    if (key.startsWith(other.key)) return this;
    if (other.key.startsWith(key)) return other;
    return _conflict;
  }
}
