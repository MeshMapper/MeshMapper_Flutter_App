import 'package:flutter/material.dart';
import 'package:hive/hive.dart';
import '../utils/ping_colors.dart';

part 'noise_floor_session.g.dart';

/// A single noise floor sample recorded at a point in time
@HiveType(typeId: 10)
class NoiseFloorSample extends HiveObject {
  @HiveField(0)
  final DateTime timestamp;

  @HiveField(1)
  final int noiseFloor; // dBm

  NoiseFloorSample({
    required this.timestamp,
    required this.noiseFloor,
  });
}

/// Type of ping event for graph markers
@HiveType(typeId: 11)
enum PingEventType {
  @HiveField(0)
  txSuccess, // Green: TX heard by repeater

  @HiveField(1)
  txFail, // Red: TX not heard

  @HiveField(2)
  rx, // Blue: Passive RX received

  @HiveField(3)
  discSuccess, // Purple: Discovery got response

  @HiveField(4)
  discFail, // Grey: Discovery no response

  @HiveField(5)
  traceSuccess, // Cyan: Trace got response

  @HiveField(6)
  traceFail, // Grey: Trace no response
}

/// Repeater info for graph markers
@HiveType(typeId: 14)
class MarkerRepeaterInfo extends HiveObject {
  @HiveField(0)
  final String repeaterId;

  @HiveField(1)
  final double snr;

  @HiveField(2)
  final int rssi;

  /// Full public key hex from DISC responses (64 chars) for exact repeater matching.
  /// Null for TX/RX pings which only have 1-byte IDs.
  @HiveField(3)
  final String? pubkeyHex;

  MarkerRepeaterInfo({
    required this.repeaterId,
    required this.snr,
    required this.rssi,
    this.pubkeyHex,
  });
}

/// A ping event marker with timestamp, type, and noise floor at time of event
@HiveType(typeId: 12)
class PingEventMarker extends HiveObject {
  @HiveField(0)
  final DateTime timestamp;

  @HiveField(1)
  final PingEventType type;

  @HiveField(2)
  final int noiseFloor; // dBm at time of event

  @HiveField(3)
  final double? latitude;

  @HiveField(4)
  final double? longitude;

  @HiveField(5)
  final List<MarkerRepeaterInfo>? repeaters;

  PingEventMarker({
    required this.timestamp,
    required this.type,
    required this.noiseFloor,
    this.latitude,
    this.longitude,
    this.repeaters,
  });

  /// Get the color for this event type
  Color get color => switch (type) {
        PingEventType.txSuccess => PingColors.txSuccess,
        PingEventType.txFail => PingColors.txFail,
        PingEventType.rx => PingColors.rx,
        PingEventType.discSuccess => PingColors.discSuccess,
        PingEventType.discFail => PingColors.discFail,
        PingEventType.traceSuccess => PingColors.traceSuccess,
        PingEventType.traceFail => PingColors.noResponse,
      };

  /// Get a display label for this event type
  String get label => switch (type) {
        PingEventType.txSuccess => 'TX Success',
        PingEventType.txFail => 'TX Fail',
        PingEventType.rx => 'RX',
        PingEventType.discSuccess => 'DISC Success',
        PingEventType.discFail => 'DISC Fail',
        PingEventType.traceSuccess => 'Trace Success',
        PingEventType.traceFail => 'Trace Fail',
      };
}

/// A recording session for noise floor and ping events
/// A session starts when the user enables Active or Passive Mode,
/// and ends when they disable it (or disconnect)
@HiveType(typeId: 13)
class NoiseFloorSession extends HiveObject {
  @HiveField(0)
  final String id; // UUID

  @HiveField(1)
  final DateTime startTime;

  @HiveField(2)
  DateTime? endTime;

  @HiveField(3)
  final String mode; // 'active' or 'passive'

  @HiveField(4)
  final List<NoiseFloorSample> samples;

  @HiveField(5)
  final List<PingEventMarker> markers;

  NoiseFloorSession({
    required this.id,
    required this.startTime,
    this.endTime,
    required this.mode,
    List<NoiseFloorSample>? samples,
    List<PingEventMarker>? markers,
  })  : samples = samples ?? [],
        markers = markers ?? [];

  /// Duration of the session
  Duration get duration => (endTime ?? DateTime.now()).difference(startTime);

  /// Whether the session is currently active (recording)
  bool get isActive => endTime == null;

  /// Display name for the mode
  String get modeDisplay => switch (mode) {
    'active' => 'Active Mode',
    'hybrid' => 'Hybrid Mode',
    'targeted' => 'Trace Mode',
    _ => 'Passive Mode',
  };

  /// Formatted duration string (M:SS or H:MM:SS for long sessions)
  String get durationDisplay {
    final d = duration;
    if (d.inHours > 0) {
      return '${d.inHours}:${(d.inMinutes % 60).toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
    }
    return '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  /// Get min and max noise floor values for chart scaling
  ({int min, int max}) get noiseFloorRange {
    if (samples.isEmpty) {
      return (min: -120, max: -60);
    }
    int minVal = samples.first.noiseFloor;
    int maxVal = samples.first.noiseFloor;
    for (final sample in samples) {
      if (sample.noiseFloor < minVal) minVal = sample.noiseFloor;
      if (sample.noiseFloor > maxVal) maxVal = sample.noiseFloor;
    }
    // Add some padding
    return (min: minVal - 5, max: maxVal + 5);
  }
}
