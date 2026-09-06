import 'package:flutter/foundation.dart';

enum ExternalCommandSource {
  watch,
  siri,
  androidAuto;

  static ExternalCommandSource? fromWire(String value) {
    for (final source in values) {
      if (source.name == value) return source;
    }
    return null;
  }
}

enum ExternalSessionCommandKind {
  startSession,
  stopSession,
  manualPing;

  static ExternalSessionCommandKind? fromWire(String value) {
    for (final kind in values) {
      if (kind.name == value) return kind;
    }
    return null;
  }
}

/// The generic session modes an external surface may request.
///
/// Trace is intentionally absent: it needs a stable repeater identity and a
/// dedicated command rather than a string smuggled through generic Start.
enum ExternalSessionMode {
  active,
  passive,
  hybrid;

  static ExternalSessionMode? fromWire(String value) {
    for (final mode in values) {
      if (mode.name == value) return mode;
    }
    return null;
  }

  String get displayName => switch (this) {
        ExternalSessionMode.active => 'Active',
        ExternalSessionMode.passive => 'Passive Discovery',
        ExternalSessionMode.hybrid => 'Hybrid',
      };
}

enum ExternalCommandDisposition {
  admitted,
  noOp,
  refused;
}

/// Stable refusal identities shared by compact and spoken presentations.
enum ExternalCommandReasonCode {
  notConnected,
  notConnectedToDevice,
  stillStopping,
  traceSessionActive,
  alreadyStarting,
  selectAntennaOption,
  selectAntennaOptionBeforePinging,
  selectPowerLevel,
  selectPowerLevelUnknownDevice,
  offlineMode,
  passiveOnly,
  zoneAtCapacity,
  floodTrafficOff,
  coolingDown,
  waitFiveSeconds,
  waitFifteenSeconds,
  pingInProgress,
  listeningForPingResponse,
  waitingForGpsLock,
  gpsDataStale,
  gpsAccuracyLow,
  anotherOperationInProgress,
  stillStartingTryStopAgain,
  sessionAlreadyEnded,
  couldNotStart,
  couldNotStop,
  pingFailed,
  appClosing,
  commandExpired,
  noRememberedCompanion,
  alreadyConnected,
  anotherCompanionConnected,
  alreadyConnecting,
  userInteractionRequired,
  airborne,
  other,
}

/// A typed reason with the exact compact text rendered by small surfaces.
///
/// [ExternalCommandReasonCode.other] preserves success text and free-form
/// provider/server failures without making those deeper layers adopt this enum.
@immutable
class ExternalCommandReason {
  const ExternalCommandReason.known(this.code)
      : assert(code != ExternalCommandReasonCode.other),
        rawText = null;

  const ExternalCommandReason.other(this.rawText)
      : code = ExternalCommandReasonCode.other;

  static const notConnected =
      ExternalCommandReason.known(ExternalCommandReasonCode.notConnected);
  static const notConnectedToDevice = ExternalCommandReason.known(
    ExternalCommandReasonCode.notConnectedToDevice,
  );
  static const stillStopping =
      ExternalCommandReason.known(ExternalCommandReasonCode.stillStopping);
  static const traceSessionActive = ExternalCommandReason.known(
    ExternalCommandReasonCode.traceSessionActive,
  );
  static const alreadyStarting =
      ExternalCommandReason.known(ExternalCommandReasonCode.alreadyStarting);
  static const selectAntennaOption = ExternalCommandReason.known(
    ExternalCommandReasonCode.selectAntennaOption,
  );
  static const selectAntennaOptionBeforePinging = ExternalCommandReason.known(
    ExternalCommandReasonCode.selectAntennaOptionBeforePinging,
  );
  static const selectPowerLevel =
      ExternalCommandReason.known(ExternalCommandReasonCode.selectPowerLevel);
  static const selectPowerLevelUnknownDevice = ExternalCommandReason.known(
    ExternalCommandReasonCode.selectPowerLevelUnknownDevice,
  );
  static const offlineMode =
      ExternalCommandReason.known(ExternalCommandReasonCode.offlineMode);
  static const passiveOnly =
      ExternalCommandReason.known(ExternalCommandReasonCode.passiveOnly);
  static const zoneAtCapacity =
      ExternalCommandReason.known(ExternalCommandReasonCode.zoneAtCapacity);
  static const floodTrafficOff =
      ExternalCommandReason.known(ExternalCommandReasonCode.floodTrafficOff);
  static const coolingDown =
      ExternalCommandReason.known(ExternalCommandReasonCode.coolingDown);
  static const waitFiveSeconds =
      ExternalCommandReason.known(ExternalCommandReasonCode.waitFiveSeconds);
  static const waitFifteenSeconds = ExternalCommandReason.known(
    ExternalCommandReasonCode.waitFifteenSeconds,
  );
  static const pingInProgress =
      ExternalCommandReason.known(ExternalCommandReasonCode.pingInProgress);
  static const listeningForPingResponse = ExternalCommandReason.known(
    ExternalCommandReasonCode.listeningForPingResponse,
  );
  static const waitingForGpsLock = ExternalCommandReason.known(
    ExternalCommandReasonCode.waitingForGpsLock,
  );
  static const gpsDataStale =
      ExternalCommandReason.known(ExternalCommandReasonCode.gpsDataStale);
  static const gpsAccuracyLow =
      ExternalCommandReason.known(ExternalCommandReasonCode.gpsAccuracyLow);
  static const anotherOperationInProgress = ExternalCommandReason.known(
    ExternalCommandReasonCode.anotherOperationInProgress,
  );
  static const stillStartingTryStopAgain = ExternalCommandReason.known(
    ExternalCommandReasonCode.stillStartingTryStopAgain,
  );
  static const sessionAlreadyEnded = ExternalCommandReason.known(
    ExternalCommandReasonCode.sessionAlreadyEnded,
  );
  static const couldNotStart =
      ExternalCommandReason.known(ExternalCommandReasonCode.couldNotStart);
  static const couldNotStop =
      ExternalCommandReason.known(ExternalCommandReasonCode.couldNotStop);
  static const pingFailed =
      ExternalCommandReason.known(ExternalCommandReasonCode.pingFailed);
  static const appClosing =
      ExternalCommandReason.known(ExternalCommandReasonCode.appClosing);
  static const commandExpired =
      ExternalCommandReason.known(ExternalCommandReasonCode.commandExpired);
  static const noRememberedCompanion = ExternalCommandReason.known(
    ExternalCommandReasonCode.noRememberedCompanion,
  );
  static const alreadyConnected =
      ExternalCommandReason.known(ExternalCommandReasonCode.alreadyConnected);
  static const anotherCompanionConnected = ExternalCommandReason.known(
    ExternalCommandReasonCode.anotherCompanionConnected,
  );
  static const alreadyConnecting =
      ExternalCommandReason.known(ExternalCommandReasonCode.alreadyConnecting);
  static const userInteractionRequired = ExternalCommandReason.known(
    ExternalCommandReasonCode.userInteractionRequired,
  );
  static const airborne =
      ExternalCommandReason.known(ExternalCommandReasonCode.airborne);

  final ExternalCommandReasonCode code;
  final String? rawText;

  String get compactText => switch (code) {
        ExternalCommandReasonCode.notConnected => 'Not connected',
        ExternalCommandReasonCode.notConnectedToDevice =>
          'Not connected to device',
        ExternalCommandReasonCode.stillStopping => 'Still stopping',
        ExternalCommandReasonCode.traceSessionActive => 'Trace session active',
        ExternalCommandReasonCode.alreadyStarting => 'Already starting',
        ExternalCommandReasonCode.selectAntennaOption =>
          'Select antenna option',
        ExternalCommandReasonCode.selectAntennaOptionBeforePinging =>
          'Select antenna option before pinging',
        ExternalCommandReasonCode.selectPowerLevel => 'Select power level',
        ExternalCommandReasonCode.selectPowerLevelUnknownDevice =>
          'Select power level (unknown device)',
        ExternalCommandReasonCode.offlineMode => 'Offline Mode',
        ExternalCommandReasonCode.passiveOnly => 'Passive Only',
        ExternalCommandReasonCode.zoneAtCapacity =>
          'Zone at TX capacity (Passive Only)',
        ExternalCommandReasonCode.floodTrafficOff => 'Flood Traffic Off',
        ExternalCommandReasonCode.coolingDown => 'Cooling down',
        ExternalCommandReasonCode.waitFiveSeconds =>
          'Wait 5 seconds between pings',
        ExternalCommandReasonCode.waitFifteenSeconds =>
          'Wait 15 seconds between manual pings',
        ExternalCommandReasonCode.pingInProgress => 'Ping in progress',
        ExternalCommandReasonCode.listeningForPingResponse =>
          'Listening for ping response',
        ExternalCommandReasonCode.waitingForGpsLock => 'Waiting for GPS lock',
        ExternalCommandReasonCode.gpsDataStale =>
          'GPS data too old (> 60 seconds)',
        ExternalCommandReasonCode.gpsAccuracyLow =>
          'GPS accuracy too low (> 100 meters)',
        ExternalCommandReasonCode.anotherOperationInProgress =>
          'Another operation is in progress',
        ExternalCommandReasonCode.stillStartingTryStopAgain =>
          'Still starting, try Stop again',
        ExternalCommandReasonCode.sessionAlreadyEnded =>
          'That session already ended',
        ExternalCommandReasonCode.couldNotStart => 'Could not start',
        ExternalCommandReasonCode.couldNotStop => 'Could not stop',
        ExternalCommandReasonCode.pingFailed => 'Ping failed',
        ExternalCommandReasonCode.appClosing => 'App closing',
        ExternalCommandReasonCode.commandExpired =>
          'Command arrived too late to run safely',
        ExternalCommandReasonCode.noRememberedCompanion =>
          'No remembered companion',
        ExternalCommandReasonCode.alreadyConnected => 'Already connected',
        ExternalCommandReasonCode.anotherCompanionConnected =>
          'Another companion is connected',
        ExternalCommandReasonCode.alreadyConnecting => 'Already connecting',
        ExternalCommandReasonCode.userInteractionRequired =>
          'User interaction required',
        ExternalCommandReasonCode.airborne =>
          'Wardriving from an aircraft is not allowed',
        ExternalCommandReasonCode.other => rawText ?? '',
      };
}

@immutable
class ExternalSessionCommand {
  const ExternalSessionCommand({
    required this.id,
    required this.source,
    required this.kind,
    required this.issuedAt,
    this.expiresAt,
    this.mode,
    this.sessionId,
  });

  final String id;
  final ExternalCommandSource source;
  final ExternalSessionCommandKind kind;
  final DateTime issuedAt;

  /// The instant the issuing surface stops waiting for a real outcome.
  ///
  /// Siri resumes its App Intent with a failure once this passes, so the phone
  /// must stop too rather than committing to the radio behind a person who was
  /// already told it did not happen. Surfaces that wait indefinitely, such as
  /// the watch, leave this null and fall back to [maximumExternalCommandAge].
  final DateTime? expiresAt;
  final String? mode;
  final String? sessionId;

  static ExternalSessionCommand? fromMap(
    Map<Object?, Object?> map, {
    required ExternalCommandSource expectedSource,
  }) {
    final id = map['id'];
    final source = map['source'];
    final kind = map['kind'];
    final issuedAtMs = map['issuedAtMs'];
    if (id is! String ||
        id.isEmpty ||
        source is! String ||
        ExternalCommandSource.fromWire(source) != expectedSource ||
        kind is! String ||
        issuedAtMs is! num) {
      return null;
    }
    final parsedKind = ExternalSessionCommandKind.fromWire(kind);
    if (parsedKind == null) return null;
    final mode = map['mode'];
    final sessionId = map['sessionId'];
    if (mode != null && mode is! String) return null;
    if (sessionId != null && sessionId is! String) return null;

    return ExternalSessionCommand(
      id: id,
      source: expectedSource,
      kind: parsedKind,
      issuedAt: DateTime.fromMillisecondsSinceEpoch(issuedAtMs.toInt()),
      mode: mode as String?,
      sessionId: sessionId as String?,
    );
  }
}

@immutable
class ExternalCommandAdmission {
  const ExternalCommandAdmission({
    required this.disposition,
    this.reason,
    this.mode,
  });

  final ExternalCommandDisposition disposition;
  final ExternalCommandReason? reason;
  final ExternalSessionMode? mode;

  bool get shouldExecute => disposition == ExternalCommandDisposition.admitted;
}

@immutable
class ExternalCommandCompletion {
  const ExternalCommandCompletion({
    required this.success,
    required this.disposition,
    this.message,
    this.sessionId,
    this.mode,
  });

  final bool success;
  final ExternalCommandDisposition disposition;
  final ExternalCommandReason? message;
  final String? sessionId;
  final ExternalSessionMode? mode;

  Map<String, Object?> toMap({String? commandId}) => {
        if (commandId != null) 'id': commandId,
        'success': success,
        'disposition': disposition.name,
        'message': message?.compactText,
        'sessionId': sessionId,
        'mode': mode?.name,
      };
}
