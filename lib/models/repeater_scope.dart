/// A repeater's scopes as the server's repeater list reports them, and the
/// pure rule that turns them into the chips the repeater detail sheet shows.
///
/// The list carries `scopes`, one entry per scope name with the time each
/// source last confirmed it (seen forwarding, reported to an observer,
/// uploaded by a wardriver's app), and the repeater's default scope as four
/// additive `default_scope*` fields. Everything is optional: an older server
/// sends none of it and the sheet then shows no Scopes row at all.
///
/// Ported from the web popup's chip strip (`mmScopeChipsHtml` in the server's
/// `dev/index.php`) so the app and the web answer the same way for the same
/// repeater. `*` means "no scope set", never a wildcard, so it reads
/// "Not set" and is never labelled "all".
library;

import '../utils/repeater_format.dart';

/// One scope name and when each source last confirmed it (Unix seconds,
/// null when that source never did).
class RepeaterScope {
  /// The scope name exactly as the server sent it, case kept. `*` is the
  /// "no scope set" entry.
  final String name;

  /// When the repeater was last seen forwarding a packet in this scope.
  final int? observedAt;

  /// How many packets it was seen forwarding in this scope.
  final int? observedPkts;

  /// What proved the forwarding: `multibyte` (a multibyte path) or the
  /// repeater's firmware version.
  final String? proof;

  /// When the repeater last reported this scope to a nearby observer.
  final int? reportedAt;

  /// When a wardriver's app last uploaded this scope for the repeater.
  final int? uploadedAt;

  const RepeaterScope({
    required this.name,
    this.observedAt,
    this.observedPkts,
    this.proof,
    this.reportedAt,
    this.uploadedAt,
  });

  /// How many of the three sources confirmed this scope.
  int get sourceCount =>
      (observedAt != null ? 1 : 0) +
      (reportedAt != null ? 1 : 0) +
      (uploadedAt != null ? 1 : 0);

  static int? _int(Object? raw) {
    if (raw is int) return raw > 0 ? raw : null;
    if (raw is num && raw.isFinite) return raw > 0 ? raw.toInt() : null;
    if (raw is String) {
      final v = int.tryParse(raw.trim());
      return v != null && v > 0 ? v : null;
    }
    return null;
  }

  /// Reads one entry, or null when it carries no usable name. A missing or
  /// non-numeric time reads as "that source never confirmed it".
  static RepeaterScope? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final name = raw['scope'];
    if (name is! String || name.trim().isEmpty) return null;
    final proof = raw['proof'];
    return RepeaterScope(
      name: name.trim(),
      observedAt: _int(raw['observed_at']),
      observedPkts: _int(raw['observed_pkts']),
      proof: proof is String && proof.isNotEmpty ? proof : null,
      reportedAt: _int(raw['reported_at']),
      uploadedAt: _int(raw['uploaded_at']),
    );
  }

  /// Reads the `scopes` array. Anything that is not a list is empty, bad
  /// entries are skipped, and a repeated name keeps its first entry.
  static List<RepeaterScope> listFromJson(Object? raw) {
    if (raw is! List) return const [];
    final seen = <String>{};
    final out = <RepeaterScope>[];
    for (final item in raw) {
      final s = fromJson(item);
      if (s != null && seen.add(s.name)) out.add(s);
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'scope': name,
        'observed_at': observedAt,
        'observed_pkts': observedPkts,
        'proof': proof,
        'reported_at': reportedAt,
        'uploaded_at': uploadedAt,
      };
}

/// One chip on the Scopes row.
class RepeaterScopeChip {
  /// The text on the chip: the scope name, `Not set` for `*`, or `?` for a
  /// default the map has not confirmed yet.
  final String label;

  /// Whether this chip carries the default star.
  final bool isDefault;

  /// One sentence per thing known about this chip, shown when it is tapped.
  final List<String> details;

  /// How many sources confirmed it (0 for a default-only chip). Sort key.
  final int sourceCount;

  final String _sortName;

  const RepeaterScopeChip({
    required this.label,
    required this.isDefault,
    required this.details,
    required this.sourceCount,
    required String sortName,
  }) : _sortName = sortName;
}

/// How many chips show before the rest fold behind a "+N more" chip.
const int kRepeaterScopeChipsShown = 4;

String _ago(int ts) {
  final a = daysAgo(ts);
  if (a.isEmpty) return '';
  return a == 'Today' ? 'today' : a;
}

/// The Scopes row's chips for one repeater, in display order (the default
/// first, then more sources, then by name). Empty when there is nothing to
/// show, in which case the row is left out.
List<RepeaterScopeChip> repeaterScopeChips({
  required List<RepeaterScope> scopes,
  String? defaultScope,
  String? defaultScopeState,
  int? defaultScopeAt,
  String? defaultScopeSrc,
}) {
  String fromLine() {
    final from = defaultScopeSrc == 'reported'
        ? 'its observer report'
        : 'its own adverts';
    final when = defaultScopeAt != null ? _ago(defaultScopeAt) : '';
    return 'Default scope, from $from${when.isEmpty ? '' : ', $when'}.';
  }

  String? defName;
  var defNone = false;
  var defUnknown = false;
  if (defaultScopeState == 'named' &&
      defaultScope != null &&
      defaultScope.trim().isNotEmpty) {
    defName = defaultScope.trim();
  } else if (defaultScopeState == 'unknown') {
    defUnknown = true;
  } else if (defaultScopeState == 'none') {
    defNone = true;
  }

  final chips = <RepeaterScopeChip>[];
  for (final s in scopes) {
    final details = <String>[];
    final isUnset = s.name == '*';
    if (isUnset) {
      details.add('Passes messages that have no scope set. A message tagged '
          'with a scope this repeater is not configured for is dropped.');
    }
    if (s.observedAt != null) {
      final pk = s.observedPkts ?? 0;
      final proof = s.proof == 'multibyte'
          ? 'a multibyte path'
          : 'its firmware version';
      final when = _ago(s.observedAt!);
      details.add('Seen forwarding $pk packet${pk == 1 ? '' : 's'}'
          '${when.isEmpty ? '' : ', last $when'} (proven by $proof).');
    }
    if (s.reportedAt != null) {
      final when = _ago(s.reportedAt!);
      details.add('Reported when a nearby observer asked it'
          '${when.isEmpty ? '' : ', $when'}.');
    }
    if (s.uploadedAt != null) {
      final when = _ago(s.uploadedAt!);
      details.add("Uploaded by a wardriver's app"
          '${when.isEmpty ? '' : ', $when'}.');
    }
    final isDefault = (defName != null && s.name == defName) ||
        (defNone && isUnset);
    if (isDefault) details.insert(isUnset ? 1 : 0, fromLine());
    chips.add(RepeaterScopeChip(
      label: isUnset ? 'Not set' : s.name,
      isDefault: isDefault,
      details: details,
      sourceCount: s.sourceCount,
      sortName: s.name,
    ));
  }
  if (defName != null && !scopes.any((s) => s.name == defName)) {
    chips.add(RepeaterScopeChip(
      label: defName,
      isDefault: true,
      details: [fromLine()],
      sourceCount: 0,
      sortName: defName,
    ));
  }
  if (defUnknown) {
    chips.add(const RepeaterScopeChip(
      label: '?',
      isDefault: true,
      details: [
        'This repeater puts a default scope on its adverts that the map has '
            'not confirmed yet.',
      ],
      sourceCount: 0,
      sortName: '',
    ));
  }
  chips.sort((a, b) {
    if (a.isDefault != b.isDefault) return a.isDefault ? -1 : 1;
    if (a.sourceCount != b.sourceCount) {
      return b.sourceCount.compareTo(a.sourceCount);
    }
    return a._sortName.toLowerCase().compareTo(b._sortName.toLowerCase());
  });
  return chips;
}
