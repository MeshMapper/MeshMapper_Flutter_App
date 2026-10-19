/// Personal repeater nicknames: the pure store and resolution rules.
///
/// A nickname is a short label the user gives one repeater (for example "Mell"
/// for the repeater whose key starts 5007). It lives only on the phone, keyed
/// by the repeater's FULL public key (the one stable identity a repeater has),
/// and takes priority over the server's name wherever a heard repeater is named
/// on the Top Heard overlay, the Live Activity, the Watch and Siri.
///
/// **A nickname is shown only when the heard ID resolves to exactly one
/// repeater.** A short path hash routinely matches several repeaters, and a
/// confidently wrong name is worse than none.
library;

import 'package:flutter/widgets.dart' show StringCharacters;

import '../models/repeater.dart';
import '../services/external_surfaces/geo/external_surface_geo_builder.dart';
import 'public_key.dart';

/// One saved nickname, with a snapshot of the repeater it was given to.
///
/// [name] and [hex] are captured when the nickname is saved so a Settings list
/// can still describe a repeater that is not in the current zone's catalogue.
/// They are display-only and never used to match a heard ID.
class RepeaterNickname {
  const RepeaterNickname({
    required this.nickname,
    required this.name,
    required this.hex,
  });

  /// The user's short label, already through
  /// [RepeaterNicknames.normalizeNickname].
  final String nickname;

  /// The server's repeater name at save time.
  final String name;

  /// `Repeater.displayHexId()` at save time.
  final String hex;

  @override
  bool operator ==(Object other) =>
      other is RepeaterNickname &&
      other.nickname == nickname &&
      other.name == name &&
      other.hex == hex;

  @override
  int get hashCode => Object.hash(nickname, name, hex);

  @override
  String toString() => 'RepeaterNickname($nickname, $name, $hex)';
}

/// Static helpers over a nickname map keyed by upper-case 64-hex public key.
class RepeaterNicknames {
  const RepeaterNicknames._();

  /// The longest nickname, in user-perceived characters.
  static const int maxLength = 8;

  /// [raw] trimmed, with every run of whitespace collapsed to one space and
  /// capped at [maxLength] characters, or null when nothing is left.
  ///
  /// The cap counts user-perceived characters (grapheme clusters), so an emoji
  /// or an accented letter is never cut in half. A cap that lands on a space
  /// is trimmed again so the result is stable under a second pass.
  ///
  /// Zero-width spaces, word joiners and byte-order marks are dropped, and a
  /// nickname of nothing but format characters (joiners, direction marks) is
  /// blank: pasted, it would save a label nobody can see. Joiners inside an
  /// emoji sequence are kept.
  static String? normalizeNickname(String? raw) {
    if (raw == null) return null;
    final collapsed =
        raw.replaceAll(_zeroWidth, '').trim().replaceAll(RegExp(r'\s+'), ' ');
    final capped = collapsed.characters.take(maxLength).toString().trim();
    if (capped.replaceAll(_format, '').trim().isEmpty) return null;
    return capped;
  }

  static final RegExp _zeroWidth = RegExp('[\u200B\u2060\uFEFF]');
  static final RegExp _format = RegExp(r'\p{Cf}', unicode: true);

  /// The nicknames persisted in Hive: a map of key to a map holding
  /// `nickname`, `name` and `hex`.
  ///
  /// Keys are stored in normalized form. An entry whose key is not a full
  /// public key, or whose nickname is blank, is dropped. Anything that is not
  /// a map, or a field that is not a string, is tolerated rather than thrown
  /// on, so a corrupt box can never stop the app starting.
  static Map<String, RepeaterNickname> sanitize(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, RepeaterNickname>{};
    for (final entry in raw.entries) {
      final key = entry.key;
      final value = entry.value;
      if (key is! String || value is! Map) continue;
      final normalizedKey = normalizePublicKey(key);
      if (normalizedKey == null) continue;
      final rawNickname = value['nickname'];
      final nickname =
          rawNickname is String ? normalizeNickname(rawNickname) : null;
      if (nickname == null) continue;
      final name = value['name'];
      final hex = value['hex'];
      out[normalizedKey] = RepeaterNickname(
        nickname: nickname,
        name: name is String ? name : '',
        // A damaged entry still shows an ID in the Settings list: the key's
        // first four characters, the same fallback setRepeaterNicknameByKey
        // uses.
        hex: hex is String && hex.trim().isNotEmpty
            ? hex
            : normalizedKey.substring(0, 4),
      );
    }
    return out;
  }

  /// [nicknames] as plain maps, the shape [sanitize] reads back from Hive.
  static Map<String, Map<String, String>> toStorage(
    Map<String, RepeaterNickname> nicknames,
  ) =>
      {
        for (final entry in nicknames.entries)
          entry.key: {
            'nickname': entry.value.nickname,
            'name': entry.value.name,
            'hex': entry.value.hex,
          },
      };

  /// The nickname saved for [repeater], matched on its full public key, or
  /// null when it has none or its `hexId` is not a full key (a repeater with an
  /// empty or short `hexId` can never be told apart from another one).
  static String? nicknameFor(
    Repeater repeater,
    Map<String, RepeaterNickname> nicknames,
  ) {
    final key = normalizePublicKey(repeater.hexId);
    return key == null ? null : nicknames[key]?.nickname;
  }

  /// [name], the server's repeater name, cut to [maxLength] user-perceived
  /// characters for a label with `…` appended when it was cut, or null when
  /// [name] is blank.
  ///
  /// A name of [maxLength] characters or fewer is returned trimmed with no
  /// ellipsis. The cut counts grapheme clusters, like [normalizeNickname], so an
  /// emoji or an accented letter is never split.
  static String? shortenServerName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    final chars = trimmed.characters;
    if (chars.length <= maxLength) return trimmed;
    return '${chars.take(maxLength).toString().trimRight()}…';
  }

  /// The label for a heard row, or null (show the hex) when the row does not
  /// resolve to exactly one repeater that has one.
  ///
  /// That is the repeater's nickname, or, with [useServerName], its server name
  /// through [shortenServerName] when it has no nickname. The server name is
  /// skipped for the placeholder name `Unknown` and for an anonymised
  /// repeater ([Repeater.isHidden]).
  ///
  /// Resolves through [ExternalSurfaceGeoBuilder.resolveOverlayRow]: the
  /// fullest [identity] the row arrived with first (a discovery response's
  /// public key, a trace's target), then [displayId], the hash it is shown
  /// under.
  ///
  /// With [useServerName] false, an empty [nicknames] returns null without
  /// scanning [repeaters], which is the common case and runs on every overlay
  /// rebuild.
  static String? labelFor({
    required String displayId,
    String? identity,
    required List<Repeater> repeaters,
    int? hopBytes,
    required Map<String, RepeaterNickname> nicknames,
    bool useServerName = false,
  }) {
    if (nicknames.isEmpty && !useServerName) return null;
    final match = ExternalSurfaceGeoBuilder.resolveOverlayRow(
      displayId: displayId,
      identity: identity,
      repeaters: repeaters,
      hopBytes: hopBytes,
    );
    if (match == null) return null;
    final nickname = nicknameFor(match, nicknames);
    if (nickname != null) return nickname;
    if (!useServerName || match.name == 'Unknown' || match.isHidden) {
      return null;
    }
    return shortenServerName(match.name);
  }
}
