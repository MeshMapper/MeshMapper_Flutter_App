import 'package:flutter/foundation.dart';

const int siriSnapshotWireVersion = 1;

enum SiriObservationKind { txEcho, passiveRx, discovery, trace }

@immutable
class SiriConnectionSnapshot {
  const SiriConnectionSnapshot({
    required this.isConnected,
    this.deviceName,
    this.batteryPercent,
    required this.gpsStatus,
  });

  final bool isConnected;
  final String? deviceName;
  final int? batteryPercent;
  final String gpsStatus;

  Map<String, Object?> toMap() => {
        'isConnected': isConnected,
        'deviceName': deviceName,
        'batteryPercent': batteryPercent,
        'gpsStatus': gpsStatus,
      };
}

@immutable
class SiriSessionSnapshot {
  const SiriSessionSnapshot({
    this.id,
    required this.active,
    required this.starting,
    required this.mode,
    required this.phase,
    required this.phaseTitle,
    this.phaseDetail,
    this.phaseEndsAt,
    this.zoneCode,
    required this.txCount,
    required this.rxCount,
    required this.discoveryCount,
    required this.traceCount,
    required this.queueSize,
    required this.uniqueRepeatersHeard,
  });

  final String? id;
  final bool active;
  final bool starting;
  final String mode;
  final String phase;
  final String phaseTitle;
  final String? phaseDetail;
  final DateTime? phaseEndsAt;
  final String? zoneCode;
  final int txCount;
  final int rxCount;
  final int discoveryCount;
  final int traceCount;
  final int queueSize;
  final int uniqueRepeatersHeard;

  Map<String, Object?> toMap() => {
        'id': id,
        'active': active,
        'starting': starting,
        'mode': mode,
        'phase': phase,
        'phaseTitle': phaseTitle,
        'phaseDetail': phaseDetail,
        'phaseEndsAtMs': phaseEndsAt?.millisecondsSinceEpoch,
        'zoneCode': zoneCode,
        'txCount': txCount,
        'rxCount': rxCount,
        'discoveryCount': discoveryCount,
        'traceCount': traceCount,
        'queueSize': queueSize,
        'uniqueRepeatersHeard': uniqueRepeatersHeard,
      };
}

@immutable
class SiriControlsSnapshot {
  const SiriControlsSnapshot({
    required this.availableStartModes,
    required this.canStart,
    this.startBlockedReason,
    required this.canStop,
    required this.canManualPing,
    this.manualPingBlockedReason,
    this.manualCooldownEndsAt,
  });

  final List<String> availableStartModes;
  final bool canStart;
  final String? startBlockedReason;
  final bool canStop;
  final bool canManualPing;
  final String? manualPingBlockedReason;
  final DateTime? manualCooldownEndsAt;

  Map<String, Object?> toMap() => {
        'availableStartModes': availableStartModes,
        'canStart': canStart,
        'startBlockedReason': startBlockedReason,
        'canStop': canStop,
        'canManualPing': canManualPing,
        'manualPingBlockedReason': manualPingBlockedReason,
        'manualCooldownEndsAtMs': manualCooldownEndsAt?.millisecondsSinceEpoch,
      };
}

@immutable
class SiriRepeaterObservation {
  const SiriRepeaterObservation({
    this.entityId,
    required this.displayHexId,
    this.name,
    required this.observedAt,
    required this.kind,
    required this.direct,
    required this.hopCount,
    this.snr,
    this.rssi,
    this.distanceM,
    this.repeaterLat,
    this.repeaterLon,
    required this.resolved,
  });

  final String? entityId;
  final String displayHexId;
  final String? name;
  final DateTime observedAt;
  final SiriObservationKind kind;
  final bool direct;
  final int hopCount;
  final double? snr;
  final int? rssi;
  final double? distanceM;
  final double? repeaterLat;
  final double? repeaterLon;
  final bool resolved;

  Map<String, Object?> toMap() => {
        'entityId': entityId,
        'displayHexId': displayHexId,
        'name': name,
        'observedAtMs': observedAt.millisecondsSinceEpoch,
        'kind': kind.name,
        'direct': direct,
        'hopCount': hopCount,
        'snr': snr,
        'rssi': rssi,
        'distanceM': distanceM,
        'repeaterLat': repeaterLat,
        'repeaterLon': repeaterLon,
        'resolved': resolved,
      };
}

@immutable
class SiriRepeaterEntitySnapshot {
  const SiriRepeaterEntitySnapshot({
    required this.id,
    required this.name,
    required this.hexId,
    this.zoneCode,
    required this.isActive,
    required this.isNew,
    this.serverLastHeard,
    this.latitude,
    this.longitude,
  });

  final String id;
  final String name;
  final String hexId;
  final String? zoneCode;
  final bool isActive;
  final bool isNew;
  final DateTime? serverLastHeard;
  final double? latitude;
  final double? longitude;

  Map<String, Object?> toMap() => {
        'id': id,
        'name': name,
        'hexId': hexId,
        'zoneCode': zoneCode,
        'isActive': isActive,
        'isNew': isNew,
        'serverLastHeardMs': serverLastHeard?.millisecondsSinceEpoch,
        'latitude': latitude,
        'longitude': longitude,
      };
}

@immutable
class SiriSnapshot {
  const SiriSnapshot({
    this.version = siriSnapshotWireVersion,
    required this.updatedAt,
    required this.connection,
    required this.session,
    required this.controls,
    required this.recentHeard,
    required this.repeaters,
  });

  final int version;
  final DateTime updatedAt;
  final SiriConnectionSnapshot connection;
  final SiriSessionSnapshot session;
  final SiriControlsSnapshot controls;
  final List<SiriRepeaterObservation> recentHeard;
  final List<SiriRepeaterEntitySnapshot> repeaters;

  Map<String, Object?> toMap() => {
        'version': version,
        'updatedAtMs': updatedAt.millisecondsSinceEpoch,
        'connection': connection.toMap(),
        'session': session.toMap(),
        'controls': controls.toMap(),
        'recentHeard': recentHeard.map((item) => item.toMap()).toList(),
        'repeaters': repeaters.map((item) => item.toMap()).toList(),
      };
}
