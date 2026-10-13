/// A multi-region group the current zone belongs to, read from the
/// `/status` answer's `zone.group` (see APP_API.md section 2).
///
/// The app uses the group only for what the user sees (labels) and where it
/// reads coverage from. The member zone's own code stays the identity of the
/// session everywhere else.
class ZoneGroup {
  /// Upper-case group code, never empty, letters and digits only. Also the
  /// subdomain of the group's own site (`<code>.meshmapper.net`).
  final String code;

  /// Display name, or null when the server sent none.
  final String? name;

  /// Member zone codes, upper-case. May be empty.
  final List<String> members;

  const ZoneGroup({required this.code, this.name, this.members = const []});
}

final RegExp _groupCodePattern = RegExp(r'^[A-Z0-9]+$');

/// Reads `zone['group']`. Anything missing or malformed is "no group", so an
/// older server (which never sends the key) behaves exactly as before.
ZoneGroup? parseZoneGroup(Object? zone) {
  if (zone is! Map) return null;
  final raw = zone['group'];
  if (raw is! Map) return null;
  final rawCode = raw['code'];
  if (rawCode is! String) return null;
  final code = rawCode.trim().toUpperCase();
  if (!_groupCodePattern.hasMatch(code)) return null;
  final rawName = raw['name'];
  final name =
      rawName is String && rawName.trim().isNotEmpty ? rawName.trim() : null;
  final rawMembers = raw['members'];
  final members = rawMembers is List
      ? rawMembers
          .whereType<String>()
          .map((m) => m.trim().toUpperCase())
          .where((m) => m.isNotEmpty)
          .toList(growable: false)
      : const <String>[];
  return ZoneGroup(code: code, name: name, members: members);
}

/// Longest zone code shown whole on the short labels (chips, status bar,
/// Live Activity, watch, Siri).
const int kShortZoneLabelMax = 4;

/// The short-label form of a zone or group code: anything longer than
/// [kShortZoneLabelMax] is cut and ends in an ellipsis. Display only; URLs
/// always use the full code.
String shortZoneLabel(String code) => code.length <= kShortZoneLabelMax
    ? code
    : '${code.substring(0, kShortZoneLabelMax)}…';

/// What a live session should do when `/status` reports a zone.
enum ZoneMove {
  /// Still in the session's own zone (or no session).
  none,

  /// Another member of the session's own group: move without the user
  /// seeing it.
  hiddenHandoff,

  /// Anything else: today's visible zone transfer.
  fullTransfer,
}

/// Pure decision for a zone change under a live session. The caller still
/// applies its own gates (connected, not Offline Mode, not in zone grace,
/// no transfer or handoff already running).
ZoneMove classifyZoneMove({
  required String? sessionZone,
  required String? sessionGroup,
  required String newZone,
  required String? newGroup,
}) {
  if (sessionZone == null || newZone.isEmpty || newZone == sessionZone) {
    return ZoneMove.none;
  }
  if (sessionGroup != null && sessionGroup == newGroup) {
    return ZoneMove.hiddenHandoff;
  }
  return ZoneMove.fullTransfer;
}

/// What `_startGroupHandoff` does once a hidden handoff has settled
/// `failed`. A failed handoff has released the old session, and a connected
/// online radio must not sit without one: uploads would throw "no
/// session_id" and the keepalive is gone.
enum GroupHandoffFollowUp {
  /// Nothing: the handoff did not fail, or something that owns its own
  /// session (a disconnect, Offline Mode, zone grace) is in charge.
  none,

  /// Re-mint through the visible transfer in the zone the phone is in NOW:
  /// the member the handoff was for, a third member a later tick moved it to,
  /// or the old member it moved back into (the transfer just auths in its
  /// target).
  transfer,

  /// No zone to re-join: end the session the way a failed visible transfer
  /// does.
  disconnect,
}

/// Pure rule for [GroupHandoffFollowUp]. A handoff that was superseded never
/// gets here: whatever superseded it owns the cleanup.
GroupHandoffFollowUp groupHandoffFollowUp({
  required bool failed,
  required bool connected,
  required bool offlineMode,
  required bool inZoneGracePeriod,
  required String? zoneCode,
}) {
  if (!failed || !connected || offlineMode || inZoneGracePeriod) {
    return GroupHandoffFollowUp.none;
  }
  if (zoneCode == null || zoneCode.isEmpty) {
    return GroupHandoffFollowUp.disconnect;
  }
  return GroupHandoffFollowUp.transfer;
}
