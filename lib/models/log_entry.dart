/// TX Log Entry
/// Reference: txLogState in wardrive.js
class TxLogEntry {
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final double power; // Power in watts (0.3, 0.6, 1.0, 2.0)
  final List<RxEvent> events; // Repeaters that heard this ping

  TxLogEntry({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.power,
    required this.events,
  });

  /// Get formatted timestamp (HH:MM:SS)
  String get timeString {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// Get formatted location (5 decimal places)
  String get locationString {
    return '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
  }

  /// Get CSV row
  String toCsv() {
    final eventsStr = events.isEmpty
        ? 'None'
        : events.map((e) => e.snr != null ? '${e.repeaterId}(${e.snr!.toStringAsFixed(2)})' : '${e.repeaterId}(null)').join(',');
    return '${timestamp.toIso8601String()},$latitude,$longitude,$power,$eventsStr';
  }
}

/// RX Event (repeater that heard a TX ping)
class RxEvent {
  final String repeaterId; // Hex ID (e.g., "4e", "b7")
  final double? snr; // Signal-to-noise ratio in dB (null for CARpeater pass-through)
  final int? rssi; // RSSI in dBm (null for CARpeater pass-through)

  RxEvent({
    required this.repeaterId,
    this.snr,
    this.rssi,
  });

  /// Get SNR color severity (red, orange, green)
  /// Returns null for CARpeater pass-through (no signal data)
  /// Reference: getSnrSeverityClass() in wardrive.js
  SnrSeverity? get severity {
    if (snr == null) return null;
    if (snr! <= -1) {
      return SnrSeverity.poor; // Red: -12 to -1 dB
    } else if (snr! <= 5) {
      return SnrSeverity.fair; // Orange: 0 to 5 dB
    } else {
      return SnrSeverity.good; // Green: 6 to 13+ dB
    }
  }
}

/// RX Log Entry (passive observation)
/// Reference: rxLogState in wardrive.js
class RxLogEntry {
  final DateTime timestamp;
  final String repeaterId; // Hex ID (e.g., "4e", "b7")
  final double? snr; // Signal-to-noise ratio in dB (null for CARpeater pass-through)
  final int? rssi; // Received signal strength indicator in dBm (null for CARpeater pass-through)
  final int pathLength; // Number of hops
  final int header; // Packet header byte
  final double latitude;
  final double longitude;

  RxLogEntry({
    required this.timestamp,
    required this.repeaterId,
    this.snr,
    this.rssi,
    required this.pathLength,
    required this.header,
    required this.latitude,
    required this.longitude,
  });

  /// Get formatted timestamp (HH:MM:SS)
  String get timeString {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// Get formatted location (5 decimal places)
  String get locationString {
    return '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
  }

  /// Get SNR color severity
  /// Returns null for CARpeater pass-through (no signal data)
  SnrSeverity? get severity {
    if (snr == null) return null;
    if (snr! <= -1) {
      return SnrSeverity.poor;
    } else if (snr! <= 5) {
      return SnrSeverity.fair;
    } else {
      return SnrSeverity.good;
    }
  }

  /// Get CSV row
  String toCsv() {
    return '${timestamp.toIso8601String()},$repeaterId,${snr ?? 'null'},${rssi ?? 'null'},'
        '$pathLength,0x${header.toRadixString(16).padLeft(2, '0')},'
        '$latitude,$longitude';
  }
}

/// Trace Log Entry (targeted zero-hop trace result)
class TraceLogEntry {
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final String targetRepeaterId;
  final int? noiseFloor;
  final double? localSnr;
  final double? remoteSnr;
  final int? localRssi;
  final bool success;

  TraceLogEntry({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.targetRepeaterId,
    this.noiseFloor,
    this.localSnr,
    this.remoteSnr,
    this.localRssi,
    required this.success,
  });

  /// Get formatted timestamp (HH:MM:SS)
  String get timeString {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// Get formatted location (5 decimal places)
  String get locationString {
    return '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
  }

  /// Get SNR color severity based on local SNR
  SnrSeverity? get severity {
    if (localSnr == null) return null;
    if (localSnr! <= -1) {
      return SnrSeverity.poor;
    } else if (localSnr! <= 5) {
      return SnrSeverity.fair;
    } else {
      return SnrSeverity.good;
    }
  }

  /// Get CSV row
  String toCsv() {
    return '${timestamp.toIso8601String()},$targetRepeaterId,${localSnr ?? 'null'},${localRssi ?? 'null'},'
        '${remoteSnr ?? 'null'},$latitude,$longitude,${noiseFloor ?? ''},$success';
  }
}

/// SNR Severity levels for color coding
enum SnrSeverity {
  poor, // Red: SNR ≤ -1 dB
  fair, // Orange: 0 dB ≤ SNR ≤ 5 dB
  good, // Green: SNR > 5 dB
}

/// Ping type for unified log view
enum PingLogType { tx, rx, disc, trace }

/// Wrapper for unified chronological ping log view
class UnifiedPingLogEntry implements Comparable<UnifiedPingLogEntry> {
  final PingLogType type;
  final DateTime timestamp;
  final dynamic entry;

  UnifiedPingLogEntry({required this.type, required this.timestamp, required this.entry});

  TxLogEntry get asTx => entry as TxLogEntry;
  RxLogEntry get asRx => entry as RxLogEntry;
  DiscLogEntry get asDisc => entry as DiscLogEntry;
  TraceLogEntry get asTrace => entry as TraceLogEntry;

  @override
  int compareTo(UnifiedPingLogEntry other) => other.timestamp.compareTo(timestamp);

  String get timeString => switch (type) {
    PingLogType.tx => asTx.timeString,
    PingLogType.rx => asRx.timeString,
    PingLogType.disc => asDisc.timeString,
    PingLogType.trace => asTrace.timeString,
  };

  String get locationString => switch (type) {
    PingLogType.tx => asTx.locationString,
    PingLogType.rx => asRx.locationString,
    PingLogType.disc => asDisc.locationString,
    PingLogType.trace => asTrace.locationString,
  };

  String toCsv() => switch (type) {
    PingLogType.tx => 'TX,${asTx.toCsv()}',
    PingLogType.rx => 'RX,${asRx.toCsv()}',
    PingLogType.disc => 'DISC,${asDisc.toCsv()}',
    PingLogType.trace => 'TRC,${asTrace.toCsv()}',
  };
}

/// User Error Entry for error log
class UserErrorEntry {
  final DateTime timestamp;
  final String message;
  final ErrorSeverity severity;

  UserErrorEntry({
    required this.timestamp,
    required this.message,
    this.severity = ErrorSeverity.error,
  });

  /// Get formatted timestamp (HH:MM:SS)
  String get timeString {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// Get CSV row
  String toCsv() {
    return '${timestamp.toIso8601String()},${severity.name},"${message.replaceAll('"', '""')}"';
  }
}

/// Error severity levels
enum ErrorSeverity {
  info,    // Blue: informational messages
  warning, // Orange: warnings
  error,   // Red: errors
}

/// Discovery Log Entry (discovery protocol observation)
/// Reference: MeshCore discovery protocol for efficient repeater mapping
class DiscLogEntry {
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final int? noiseFloor;
  List<DiscoveredNodeEntry> discoveredNodes;

  DiscLogEntry({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    this.noiseFloor,
    required this.discoveredNodes,
  });

  /// Get formatted timestamp (HH:MM:SS)
  String get timeString {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// Get formatted location (5 decimal places)
  String get locationString {
    return '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
  }

  /// Get node count
  int get nodeCount => discoveredNodes.length;

  /// Get CSV row
  String toCsv() {
    final nodesStr = discoveredNodes.isEmpty
        ? 'None'
        : discoveredNodes.map((n) => '${n.repeaterId}${n.nodeTypeLabel}(${n.localSnr.toStringAsFixed(2)})').join(',');
    return '${timestamp.toIso8601String()},$latitude,$longitude,${noiseFloor ?? ''},${discoveredNodes.length},$nodesStr';
  }
}

/// Discovered node entry for log display
class DiscoveredNodeEntry {
  final String repeaterId;      // First N hex chars of pubkey based on hopBytes (e.g., "4E", "4E7A", "4E7A3B")
  final String nodeType;        // "REPEATER" or "ROOM"
  final double localSnr;        // SNR as seen by local device (dB)
  final int localRssi;          // RSSI as seen by local device (dBm)
  final double remoteSnr;       // SNR as seen by remote node (dB)
  final String? pubkeyHex;      // Full public key hex (64 chars) for exact repeater matching

  DiscoveredNodeEntry({
    required this.repeaterId,
    required this.nodeType,
    required this.localSnr,
    required this.localRssi,
    required this.remoteSnr,
    this.pubkeyHex,
  });

  /// Get short display label: "(R)" for REPEATER, "(RM)" for ROOM
  String get nodeTypeLabel => nodeType == 'REPEATER' ? '(R)' : '(RM)';

  /// Get SNR color severity based on local SNR
  SnrSeverity get severity {
    if (localSnr <= -1) {
      return SnrSeverity.poor;
    } else if (localSnr <= 5) {
      return SnrSeverity.fair;
    } else {
      return SnrSeverity.good;
    }
  }
}
