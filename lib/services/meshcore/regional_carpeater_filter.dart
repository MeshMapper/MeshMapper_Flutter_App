import '../../utils/public_key.dart';

/// The region's shared CARpeater list, as served by `/auth` `carpeaters`.
///
/// Keys are upper-case 64-hex public keys. The user's own CARpeater (when its
/// switch is on) is counted but excluded from the drop set, because that one
/// keeps the pass-through behaviour in `TxTracker` and `RxLogger`. Everyone
/// else's is a plain drop: a packet through someone else's car says nothing
/// about coverage at this phone's position.
///
/// A path hop is matched on its own width (2 to 8 hex, whatever the
/// region's hop byte setting produces), a discovery response on the full key.
/// The instance is immutable; the provider builds a new one on every auth
/// answer and every preference change.
class RegionalCarpeaterFilter {
  RegionalCarpeaterFilter({Iterable<String> keys = const [], String? ownKey})
      : keys = List.unmodifiable(sanitize(keys)),
        ownKey = normalizePublicKey(ownKey) {
    final drop = Set<String>.of(this.keys);
    if (this.ownKey != null) drop.remove(this.ownKey);
    _dropSet = Set.unmodifiable(drop);
  }

  static final RegExp _hexOnly = RegExp(r'^[0-9A-F]+$');

  /// Every key the region shares, the user's own included when present.
  final List<String> keys;

  /// The user's own CARpeater, excluded from [dropSet]. Null when the switch
  /// is off or no full key is set.
  final String? ownKey;

  late final Set<String> _dropSet;

  /// The keys that are dropped outright.
  Set<String> get dropSet => _dropSet;

  /// How many keys the region shares (what Settings shows).
  int get count => keys.length;

  /// Full keys only, upper-cased, deduplicated and sorted. Anything that is
  /// not a list, or an entry that is not a full key, is left out.
  static List<String> sanitize(dynamic raw) {
    if (raw is! Iterable) return const [];
    final out = <String>{};
    for (final entry in raw) {
      if (entry is! String) continue;
      final key = normalizePublicKey(entry);
      if (key != null) out.add(key);
    }
    return out.toList()..sort();
  }

  /// True when a path hop (2 to 8 hex) is the prefix of a dropped key.
  bool matchesHop(String hopHex) {
    final hop = hopHex.trim().toUpperCase();
    if (hop.isEmpty || hop.length > 64 || !_hexOnly.hasMatch(hop)) {
      return false;
    }
    for (final key in _dropSet) {
      if (key.startsWith(hop)) return true;
    }
    return false;
  }

  /// True when a full public key is dropped.
  bool matchesKey(String pubkeyHex) {
    final key = normalizePublicKey(pubkeyHex);
    return key != null && _dropSet.contains(key);
  }
}
