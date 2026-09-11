/// The radio preset filter the app sends to the region server's doors
/// (`vector_tile.php`, `app_coverage.php`, `get_repeaters.php`).
///
/// The radio reports its configuration as the tag `freqMHz,bwKHz,SF,CR`
/// (`SelfInfo.radioConfigApi`, e.g. `910.525,62.5,7,5`). The filter is the
/// first three slots as the server's per-slot parameters `f_freq`, `f_bw`
/// and `f_sf`, matched exactly against the stored tag's slots. The coding
/// rate is left out on purpose, so a channel matches whatever coding rate
/// people run on it. Contract: the wiki's Coverage API "Filtering" section
/// and `MeshMapper_Server/docs/HANDOFF-app-radio-preset.md`.
///
/// Fail open: a null, short or partly unknown tag gives null, and every
/// caller sends no filter at all in that case.
Map<String, String>? radioFilterFromTag(String? tag) {
  if (tag == null || tag.isEmpty) return null;
  final parts = tag.split(',');
  if (parts.length < 4) return null;
  final freq = parts[0].trim();
  final bw = parts[1].trim();
  final sf = parts[2].trim();
  if (freq.isEmpty || bw.isEmpty || sf.isEmpty) return null;
  // SelfInfo writes 0 for a slot the firmware did not report. A filter on
  // it would match nothing, so the whole filter is off instead.
  if (freq == '0' || bw == '0' || sf == '0') return null;
  return {'f_freq': freq, 'f_bw': bw, 'f_sf': sf};
}

/// One string for "did the filter change": `freq,bw,sf`, or null when there
/// is no filter. Used as the cache key by the smart pinging lookup and the
/// map's overlay.
String? radioFilterKey(Map<String, String>? filter) {
  if (filter == null) return null;
  return '${filter['f_freq']},${filter['f_bw']},${filter['f_sf']}';
}
