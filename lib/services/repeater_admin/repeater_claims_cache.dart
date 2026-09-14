import 'repeater_admin_models.dart';

/// Immutable per-companion cache of the claims returned by the repeater API.
///
/// A missing companion key means no companion is connected, so [claimsFor]
/// returns the deduplicated offline list. A connected companion with no cache
/// entry has no known claims yet and deliberately receives an empty list.
class RepeaterClaimsCache {
  final Map<String, List<RepeaterClaim>> _claimsByPubkey;

  RepeaterClaimsCache(Map<String, List<RepeaterClaim>> entries)
      : _claimsByPubkey = Map.unmodifiable(<String, List<RepeaterClaim>>{
          for (final entry in entries.entries)
            entry.key.toUpperCase():
                List<RepeaterClaim>.unmodifiable(entry.value),
        });

  /// Claims for the connected companion, or the deduplicated offline list.
  List<RepeaterClaim> claimsFor(String? connectedPublicKey) {
    final key = _normalizedKey(connectedPublicKey);
    if (key != null) {
      return List<RepeaterClaim>.unmodifiable(
          _claimsByPubkey[key] ?? const <RepeaterClaim>[]);
    }

    final seen = <String>{};
    final claims = <RepeaterClaim>[];
    for (final list in _claimsByPubkey.values) {
      for (final claim in list) {
        if (seen.add(claim.repeaterHex.toUpperCase())) claims.add(claim);
      }
    }
    return List.unmodifiable(claims);
  }

  /// Returns a replacement cache with [repeaterHex] removed only for the
  /// connected companion. No companion key leaves this cache unchanged.
  RepeaterClaimsCache removeForCurrent(
      String? connectedPublicKey, String repeaterHex) {
    final key = _normalizedKey(connectedPublicKey);
    if (key == null) return this;

    final wanted = repeaterHex.toUpperCase();
    return RepeaterClaimsCache({
      for (final entry in _claimsByPubkey.entries)
        entry.key: entry.key == key
            ? entry.value
                .where((claim) => claim.repeaterHex.toUpperCase() != wanted)
                .toList()
            : entry.value,
    });
  }

  /// Returns a replacement cache for a successful `mine` response when the
  /// same companion is still connected. Returns null after an identity change.
  RepeaterClaimsCache? replaceForCurrent({
    required String? requestKey,
    required String? currentKey,
    required List<RepeaterClaim> claims,
  }) {
    final requested = _normalizedKey(requestKey);
    if (requested == null || requested != _normalizedKey(currentKey)) {
      return null;
    }
    return RepeaterClaimsCache({
      ..._claimsByPubkey,
      requested: claims,
    });
  }

  /// A copy suitable for the provider's existing persistence format.
  Map<String, List<RepeaterClaim>> get snapshot => {
        for (final entry in _claimsByPubkey.entries)
          entry.key: List<RepeaterClaim>.from(entry.value),
      };

  String? _normalizedKey(String? key) {
    final trimmed = key?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed.toUpperCase();
  }
}
