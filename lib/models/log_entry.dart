/// TX Log Entry
/// Reference: txLogState in wardrive.js
class TxLogEntry {
  final DateTime timestamp;
  final double latitude;
  final double longitude;
  final int power;
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
        : events.map((e) => '${e.repeaterId}(${e.snr.toStringAsFixed(2)})').join(',');
    return '${timestamp.toIso8601String()},$latitude,$longitude,$power,$eventsStr';
  }
}

/// RX Event (repeater that heard a TX ping)
class RxEvent {
  final String repeaterId; // Hex ID (e.g., "4e", "b7")
  final double snr; // Signal-to-noise ratio in dB
  final int rssi; // RSSI in dBm

  RxEvent({
    required this.repeaterId,
    required this.snr,
    this.rssi = 0,
  });

  /// Get SNR color severity (red, orange, green)
  /// Reference: getSnrSeverityClass() in wardrive.js
  SnrSeverity get severity {
    if (snr <= -1) {
      return SnrSeverity.poor; // Red: -12 to -1 dB
    } else if (snr <= 5) {
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
  final double snr; // Signal-to-noise ratio in dB
  final int rssi; // Received signal strength indicator in dBm
  final int pathLength; // Number of hops
  final int header; // Packet header byte
  final double latitude;
  final double longitude;

  RxLogEntry({
    required this.timestamp,
    required this.repeaterId,
    required this.snr,
    required this.rssi,
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
  SnrSeverity get severity {
    if (snr <= -1) {
      return SnrSeverity.poor;
    } else if (snr <= 5) {
      return SnrSeverity.fair;
    } else {
      return SnrSeverity.good;
    }
  }

  /// Get CSV row
  String toCsv() {
    return '${timestamp.toIso8601String()},$repeaterId,$snr,$rssi,'
        '$pathLength,0x${header.toRadixString(16).padLeft(2, '0')},'
        '$latitude,$longitude';
  }
}

/// SNR Severity levels for color coding
enum SnrSeverity {
  poor, // Red: SNR ≤ -1 dB
  fair, // Orange: 0 dB ≤ SNR ≤ 5 dB
  good, // Green: SNR > 5 dB
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
