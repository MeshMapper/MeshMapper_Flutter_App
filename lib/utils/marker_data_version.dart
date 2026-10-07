/// Hash inputs for the map's marker data version.
///
/// The map pin lists are capped rolling FIFOs: once full, every add evicts one
/// entry, so the length stops changing. A version built from lengths alone then
/// misses a new pin whenever the evicted and added entries carry the same echo
/// or node counts (a dead area: zero and zero), and the map never draws it.
///
/// This signature folds in the IDENTITY of both ends of the list, so an add at
/// either end and an eviction at either end each change it. O(1): it reads the
/// length and two elements, never walks the list. The ping and log entry
/// classes do not override `==`, so `identityHashCode` is used explicitly to
/// keep that guarantee even if one ever gains value equality.
int cappedListSignature(List<Object?> list) {
  if (list.isEmpty) return 0;
  return Object.hash(
    list.length,
    identityHashCode(list.first),
    identityHashCode(list.last),
  );
}
