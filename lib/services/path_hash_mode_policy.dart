/// The path width the companion should use for the current API policy.
///
/// Without regional enforcement, return to the width reported by the device
/// firmware rather than retaining a previously enforced runtime width.
({int desiredHopBytes, bool needsRadioWrite}) resolvePathHashModePolicy({
  required int deviceHopBytes,
  required int currentRuntimeHopBytes,
  required int enforcedHopBytes,
  required bool enforceHopBytes,
}) {
  final desiredHopBytes = enforceHopBytes ? enforcedHopBytes : deviceHopBytes;
  return (
    desiredHopBytes: desiredHopBytes,
    needsRadioWrite: desiredHopBytes != currentRuntimeHopBytes,
  );
}
