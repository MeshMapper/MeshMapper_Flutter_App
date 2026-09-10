import '../../models/repeater.dart';
import '../../utils/public_key.dart';

const String kChooseFromListHint = 'Choose from the list';
const String kCompanionFirmwareFloorHint =
    'Manage needs companion firmware v1.9.0 or newer';

/// The companion firmware floor for repeater administration: v1.9.0 added
/// the login reply's trailing bytes and is the release pair of the repeater
/// side's GET_ACCESS_LIST and GET_NEIGHBOURS.
const int kCompanionFloorMajor = 1;
const int kCompanionFloorMinor = 9;
const int kCompanionFloorPatch = 0;

final RegExp _versionRe = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)');

/// True when the radio's version string ("v1.14.0-9f1a3ea", "1.9.1") is at
/// or above major.minor.patch. Null, empty or unparseable is below the floor:
/// firmware old enough to omit the string is older than v1.9.0.
bool companionFirmwareAtLeast(String? versionString,
    {required int major, required int minor, required int patch}) {
  if (versionString == null) return false;
  final m = _versionRe.firstMatch(versionString.trim());
  if (m == null) return false;
  final v = [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)];
  final floor = [major, minor, patch];
  for (var i = 0; i < 3; i++) {
    if (v[i] != floor[i]) return v[i] > floor[i];
  }
  return true;
}

/// Which repeater the Trace row's Manage button would open.
///
/// The text field is the selection. A repeater picked from the list is kept
/// while the typed text still prefixes its full key; otherwise the typed ID is
/// resolved against the loaded list and counts only when it matches exactly
/// one repeater that carries a full 64-hex key.
Repeater? resolveManageTarget({
  required String typedId,
  required Repeater? picked,
  required List<Repeater> repeaters,
}) {
  final typed = typedId.trim().toUpperCase();
  if (picked != null && isFullPublicKey(picked.hexId)) {
    if (picked.hexId.toUpperCase().startsWith(typed)) return picked;
  }
  if (typed.isEmpty) return null;
  Repeater? match;
  for (final r in repeaters) {
    if (!isFullPublicKey(r.hexId)) continue;
    if (!r.hexId.toUpperCase().startsWith(typed)) continue;
    if (match != null) return null; // ambiguous
    match = r;
  }
  return match;
}

/// Why a repeater admin session may not open right now, or null when it may.
/// Shared by the Trace row tooltip, the detail sheet, My Repeaters and the
/// provider's own refusal, so every surface gives the same answer.
String? manageBlockReason({
  required bool isConnected,
  required bool isAnyModeRunning,
  required bool isPingInProgress,
  required bool isPingSending,
  required bool isRepeaterAdminActive,
  required bool isAutoReconnecting,
  required bool companionFirmwareSupported,
}) {
  if (!isConnected || isAutoReconnecting) {
    return 'Connect a radio to manage this repeater';
  }
  if (!companionFirmwareSupported) return kCompanionFirmwareFloorHint;
  if (isAnyModeRunning) return 'Stop the running mode first';
  if (isPingInProgress || isPingSending) {
    return 'Wait for the current ping to finish';
  }
  if (isRepeaterAdminActive) return 'A repeater session is already open';
  return null;
}
