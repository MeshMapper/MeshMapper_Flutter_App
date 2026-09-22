import '../../models/repeater.dart';
import '../../utils/public_key.dart';

const String kChooseFromListHint = 'Choose from the list';
const String kCompanionFirmwareFloorHint =
    'Update companion firmware to use Manage';

/// Companion capability code introduced with MeshCore v1.9.0, which forwards
/// the login reply's ACL permissions and repeater firmware level.
/// This is FIRMWARE_VER_CODE, byte 1 of RESP_CODE_DEVICE_INFO, not the release
/// string: forks can use their own release numbering.
const int kRepeaterAdminCompanionVersionCode = 7;

bool companionSupportsRepeaterAdmin(int? firmwareVersionCode) =>
    firmwareVersionCode != null &&
    firmwareVersionCode >= kRepeaterAdminCompanionVersionCode;

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
