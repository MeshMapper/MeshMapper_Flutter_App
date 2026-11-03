import '../../providers/app_state_provider.dart' show AutoMode;

/// The Android foreground-service notification's title and body.
///
/// One source for both lines. The background isolate composes neither: it is
/// handed the finished strings and only displays them, so the mode name comes
/// from the [AutoMode] enum's own [AutoMode.displayName] (which already reads
/// Trace for targeted) instead of one of four hand-written copies scattered
/// through the provider.
///
/// Pure: the same inputs always give the same strings, so it is checkable in a
/// table the way the phase and label resolvers are.
({String title, String body}) androidNotificationContent({
  required AutoMode mode,
  required int txCount,
  required int rxCount,
  required int queueSize,
}) {
  final body = switch (mode) {
    AutoMode.passive => 'RX: $rxCount | Queue: $queueSize',
    AutoMode.targeted => 'Trace: $txCount | RX: $rxCount | Queue: $queueSize',
    _ => 'TX: $txCount | RX: $rxCount | Queue: $queueSize',
  };
  return (title: 'MeshMapper - ${mode.displayName} Mode', body: body);
}

/// The notification while a radio is connected and no mode runs. The Android
/// session service shows a notification for the whole connection, not only
/// while a mode runs, so this is what it reads between modes.
({String title, String body}) androidConnectedNotificationContent({
  required String radioName,
}) =>
    (title: 'MeshMapper - Connected', body: 'Connected to $radioName');

/// The notification while the zone grace period looks for a zone to move to.
/// The radio stays connected through it, so the service keeps running.
({String title, String body}) androidZoneGraceNotificationContent() =>
    (title: 'MeshMapper - Outside zone', body: 'Searching for a nearby zone');
