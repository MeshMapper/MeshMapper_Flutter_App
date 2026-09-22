import '../models/repeater.dart';

const int rcFullKeyMin = 16;
const int rcTwinMinRun = 24;

String rcCleanHex(String? id) => (id ?? '')
    .replaceAll('!', '')
    .replaceAll(RegExp('0x', caseSensitive: false), '')
    .toLowerCase();

int _rcEffHex(int advertBytes, bool multibyteCapable) {
  final advert = advertBytes.clamp(1, 3);
  return multibyteCapable ? (advert * 2).clamp(4, 6) : 2;
}

int _rcSharedRun(String a, String b) {
  final n = a.length < b.length ? a.length : b.length;
  var prefix = 0;
  while (prefix < n && a[prefix] == b[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < n && a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  return prefix > suffix ? prefix : suffix;
}

bool _rcSameTwinCluster(String a, String b) {
  if (a == b) return true;
  if (a.length < rcFullKeyMin || b.length < rcFullKeyMin) return false;
  return _rcSharedRun(a, b) >= rcTwinMinRun;
}

int _enabledRank(Repeater repeater) =>
    repeater.enabled == 1 ? 2 : (repeater.enabled == 2 ? 1 : 0);

bool _rcTwinBetter(Repeater candidate, Repeater current) {
  final candidateHasCoordinates = !candidate.lat.isNaN && !candidate.lon.isNaN;
  final currentHasCoordinates = !current.lat.isNaN && !current.lon.isNaN;
  if (candidateHasCoordinates != currentHasCoordinates) {
    return candidateHasCoordinates;
  }
  final candidateRank = _enabledRank(candidate);
  final currentRank = _enabledRank(current);
  if (candidateRank != currentRank) return candidateRank > currentRank;
  if (candidate.advertBytes != current.advertBytes) {
    return candidate.advertBytes > current.advertBytes;
  }
  return candidate.multibyteCapable && !current.multibyteCapable;
}

Repeater _rcMergeInto(Repeater parent, Repeater fragment) {
  final parentMissingCoordinates = parent.lat.isNaN || parent.lon.isNaN;
  final fragmentHasCoordinates = !fragment.lat.isNaN && !fragment.lon.isNaN;
  return parent.copyWith(
    enabled: parent.enabled != 1 && fragment.enabled == 1 ? 1 : parent.enabled,
    advertBytes: fragment.advertBytes > parent.advertBytes
        ? fragment.advertBytes
        : parent.advertBytes,
    multibyteCapable: parent.multibyteCapable || fragment.multibyteCapable,
    lat: parentMissingCoordinates && fragmentHasCoordinates
        ? fragment.lat
        : parent.lat,
    lon: parentMissingCoordinates && fragmentHasCoordinates
        ? fragment.lon
        : parent.lon,
  );
}

List<Repeater> _rcCollapseTwins(List<Repeater> repeaters) {
  if (repeaters.length < 2) return List<Repeater>.of(repeaters);
  final reps = List<Repeater>.of(repeaters);
  final dropped = List<bool>.filled(reps.length, false);
  final hexes =
      reps.map((r) => rcCleanHex(r.hexId.isNotEmpty ? r.hexId : r.id)).toList();
  for (var i = 0; i < reps.length; i++) {
    if (dropped[i] || hexes[i].length < rcFullKeyMin) continue;
    for (var j = i + 1; j < reps.length; j++) {
      if (dropped[j] || hexes[j].length < rcFullKeyMin) continue;
      if (!_rcSameTwinCluster(hexes[i], hexes[j])) continue;
      if (_rcTwinBetter(reps[j], reps[i])) {
        reps[j] = _rcMergeInto(reps[j], reps[i]);
        dropped[i] = true;
        break;
      }
      reps[i] = _rcMergeInto(reps[i], reps[j]);
      dropped[j] = true;
    }
  }
  return [
    for (var i = 0; i < reps.length; i++)
      if (!dropped[i]) reps[i]
  ];
}

List<Repeater> _rcCollapseFragments(List<Repeater> repeaters) {
  if (repeaters.length < 2) return List<Repeater>.of(repeaters);
  final reps = List<Repeater>.of(repeaters);
  final dropped = List<bool>.filled(reps.length, false);
  for (var fragmentIndex = 0; fragmentIndex < reps.length; fragmentIndex++) {
    final fragmentHex = rcCleanHex(
      reps[fragmentIndex].hexId.isNotEmpty
          ? reps[fragmentIndex].hexId
          : reps[fragmentIndex].id,
    );
    if (fragmentHex.length < 2 || fragmentHex.length >= rcFullKeyMin) continue;
    var parentIndex = -1;
    var parentCount = 0;
    for (var candidateIndex = 0;
        candidateIndex < reps.length;
        candidateIndex++) {
      if (candidateIndex == fragmentIndex || dropped[candidateIndex]) continue;
      final candidateHex = rcCleanHex(
        reps[candidateIndex].hexId.isNotEmpty
            ? reps[candidateIndex].hexId
            : reps[candidateIndex].id,
      );
      if (candidateHex.length < rcFullKeyMin) continue;
      if (candidateHex.startsWith(fragmentHex)) {
        parentIndex = candidateIndex;
        parentCount++;
        if (parentCount > 1) break;
      }
    }
    if (parentCount == 1) {
      reps[parentIndex] = _rcMergeInto(reps[parentIndex], reps[fragmentIndex]);
      dropped[fragmentIndex] = true;
    }
  }
  return [
    for (var i = 0; i < reps.length; i++)
      if (!dropped[i]) reps[i]
  ];
}

/// Applies the web client's load-time collision pass to immutable repeaters.
///
/// Corrupted twins and unique fragments are collapsed first. Existing
/// server-side exclusions are reset, then each survivor is judged at its own
/// effective on-air ID width.
List<Repeater> rcComputeExclusions(List<Repeater> repeaters) {
  final collapsed = _rcCollapseFragments(_rcCollapseTwins(repeaters));
  final reset = collapsed
      .map((repeater) =>
          repeater.enabled == 2 ? repeater.copyWith(enabled: 1) : repeater)
      .toList();
  final buckets = <String, List<Repeater>>{};
  for (final repeater in reset) {
    final hex = rcCleanHex(
      repeater.hexId.isNotEmpty ? repeater.hexId : repeater.id,
    );
    if (hex.length < 2) continue;
    (buckets[hex.substring(0, 2)] ??= []).add(repeater);
  }

  return reset.map((repeater) {
    final hex = rcCleanHex(
      repeater.hexId.isNotEmpty ? repeater.hexId : repeater.id,
    );
    if (hex.length < 2) return repeater;
    final width = _rcEffHex(
      repeater.advertBytes,
      repeater.multibyteCapable,
    );
    final mine = hex.substring(0, width.clamp(0, hex.length));
    final excluded =
        (buckets[hex.substring(0, 2)] ?? const <Repeater>[]).any((other) {
      final otherHex = rcCleanHex(
        other.hexId.isNotEmpty ? other.hexId : other.id,
      );
      if (identical(other, repeater) || otherHex == hex) return false;
      if (_rcSameTwinCluster(otherHex, hex)) return false;
      final end = width.clamp(0, otherHex.length);
      return otherHex.substring(0, end) == mine;
    });
    return excluded ? repeater.copyWith(enabled: 2) : repeater;
  }).toList();
}

/// Returns the web conflict kind for a registered repeater in its first-byte
/// group: empty, `ambiguous`, `2`, or `3`.
String repeaterConflictKind(List<Repeater> repeaters, Repeater target) {
  final hex = rcCleanHex(target.hexId.isNotEmpty ? target.hexId : target.id);
  if (hex.length < 2) return '';
  var hasOther = false;
  var sharesTwoBytes = false;
  var sharesThreeBytes = false;
  for (final other in repeaters) {
    final otherHex =
        rcCleanHex(other.hexId.isNotEmpty ? other.hexId : other.id);
    if (otherHex == hex) continue;
    hasOther = true;
    if (_samePrefix(otherHex, hex, 4)) sharesTwoBytes = true;
    if (_samePrefix(otherHex, hex, 6)) sharesThreeBytes = true;
  }
  if (!hasOther) return '';
  if (target.isHidden || !target.multibyteCapable) return 'ambiguous';
  if (sharesThreeBytes) return '3';
  if (sharesTwoBytes) return '2';
  return '';
}

bool _samePrefix(String a, String b, int width) {
  final aEnd = width.clamp(0, a.length);
  final bEnd = width.clamp(0, b.length);
  return a.substring(0, aEnd) == b.substring(0, bEnd);
}

/// The repeaters whose ID is ambiguous, keyed by cleaned full hex.
///
/// Takes the output of [rcComputeExclusions] and reads the verdict that pass
/// already reached: a repeater is ambiguous when its key collides at the width
/// it actually advertises (`enabled == 2`), which is the only thing the web
/// map and its popup read. The byte-depth answer from [repeaterConflictKind]
/// belongs to the ID-Usage grid's chips and must NOT be folded in here: a
/// three-byte repeater that shares only its first two bytes with a neighbour
/// is a 2-Byte Conflict in that grid, yet it is still uniquely addressable on
/// the air, so the map does not call it ambiguous.
Set<String> rcConflictHexIds(List<Repeater> repeaters) => Set.unmodifiable({
      for (final repeater in repeaters)
        if (repeater.enabled == 2) rcCleanHex(repeater.hexId),
    });
