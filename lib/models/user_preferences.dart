/// User preferences for wardriving configuration
/// Reference: Settings in wardrive.js
class UserPreferences {
  /// Power level in watts (0.3, 0.6, 1.0, 2.0)
  final double powerLevel;

  /// TX power in dBm (22, 28, 30, 33)
  final int txPower;

  /// External antenna enabled
  final bool externalAntenna;

  /// External antenna has been explicitly set by user (required before pinging)
  final bool externalAntennaSet;

  /// Auto-ping interval in seconds (15, 30, 60)
  final int autoPingInterval;

  /// Ignore carpeater signals (RSSI ≥ -30 dBm)
  final bool ignoreCarpeater;

  /// Repeater ID to ignore (hex string, e.g., "FF")
  final String? ignoreRepeaterId;

  /// Power was auto-set based on device model (not manually selected)
  final bool autoPowerSet;

  /// Power level was manually selected by user
  final bool powerLevelSet;

  /// Offline mode enabled (no API uploads, accumulates to session files)
  final bool offlineMode;

  /// IATA zone code for geo-auth (determined from zone status response)
  final String? iataCode;

  /// Background mode enabled (requests "Always" location permission on iOS)
  final bool backgroundModeEnabled;

  /// Developer mode enabled (unlocked by tapping version 7 times)
  final bool developerModeEnabled;

  /// Map tile style (dark, light, satellite)
  final String mapStyle;

  /// Close app after disconnect (Android only)
  final bool closeAppAfterDisconnect;

  /// App theme mode (dark, light)
  final String themeMode;

  const UserPreferences({
    this.powerLevel = 0.3,
    this.txPower = 22,
    this.externalAntenna = false,
    this.externalAntennaSet = false,
    this.autoPingInterval = 30,
    this.ignoreCarpeater = false,
    this.ignoreRepeaterId,
    this.autoPowerSet = false,
    this.powerLevelSet = false,
    this.offlineMode = false,
    this.iataCode,
    this.backgroundModeEnabled = false,
    this.developerModeEnabled = false,
    this.mapStyle = 'dark',
    this.closeAppAfterDisconnect = false,
    this.themeMode = 'dark',
  });

  /// Create from JSON (for persistence)
  factory UserPreferences.fromJson(Map<String, dynamic> json) {
    return UserPreferences(
      powerLevel: (json['powerLevel'] as num?)?.toDouble() ?? 0.3,
      txPower: (json['txPower'] as int?) ?? 22,
      externalAntenna: (json['externalAntenna'] as bool?) ?? false,
      externalAntennaSet: (json['externalAntennaSet'] as bool?) ?? false,
      autoPingInterval: (json['autoPingInterval'] as int?) ?? 30,
      ignoreCarpeater: (json['ignoreCarpeater'] as bool?) ?? false,
      ignoreRepeaterId: json['ignoreRepeaterId'] as String?,
      autoPowerSet: (json['autoPowerSet'] as bool?) ?? false,
      powerLevelSet: (json['powerLevelSet'] as bool?) ?? false,
      offlineMode: false, // Never persist - always off by default
      iataCode: json['iataCode'] as String?,
      backgroundModeEnabled: (json['backgroundModeEnabled'] as bool?) ?? false,
      developerModeEnabled: (json['developerModeEnabled'] as bool?) ?? false,
      mapStyle: (json['mapStyle'] as String?) ?? 'dark',
      closeAppAfterDisconnect: (json['closeAppAfterDisconnect'] as bool?) ?? false,
      themeMode: (json['themeMode'] as String?) ?? 'dark',
    );
  }

  /// Convert to JSON (for persistence)
  Map<String, dynamic> toJson() {
    return {
      'powerLevel': powerLevel,
      'txPower': txPower,
      'externalAntenna': externalAntenna,
      'externalAntennaSet': externalAntennaSet,
      'autoPingInterval': autoPingInterval,
      'ignoreCarpeater': ignoreCarpeater,
      'ignoreRepeaterId': ignoreRepeaterId,
      'autoPowerSet': autoPowerSet,
      'powerLevelSet': powerLevelSet,
      // offlineMode intentionally not persisted - always off on app start
      'iataCode': iataCode,
      'backgroundModeEnabled': backgroundModeEnabled,
      'developerModeEnabled': developerModeEnabled,
      'mapStyle': mapStyle,
      'closeAppAfterDisconnect': closeAppAfterDisconnect,
      'themeMode': themeMode,
    };
  }

  /// Copy with modifications
  UserPreferences copyWith({
    double? powerLevel,
    int? txPower,
    bool? externalAntenna,
    bool? externalAntennaSet,
    int? autoPingInterval,
    bool? ignoreCarpeater,
    String? ignoreRepeaterId,
    bool? autoPowerSet,
    bool? powerLevelSet,
    bool? offlineMode,
    String? iataCode,
    bool? backgroundModeEnabled,
    bool? developerModeEnabled,
    String? mapStyle,
    bool? closeAppAfterDisconnect,
    String? themeMode,
  }) {
    return UserPreferences(
      powerLevel: powerLevel ?? this.powerLevel,
      txPower: txPower ?? this.txPower,
      externalAntenna: externalAntenna ?? this.externalAntenna,
      externalAntennaSet: externalAntennaSet ?? this.externalAntennaSet,
      autoPingInterval: autoPingInterval ?? this.autoPingInterval,
      ignoreCarpeater: ignoreCarpeater ?? this.ignoreCarpeater,
      ignoreRepeaterId: ignoreRepeaterId ?? this.ignoreRepeaterId,
      autoPowerSet: autoPowerSet ?? this.autoPowerSet,
      powerLevelSet: powerLevelSet ?? this.powerLevelSet,
      offlineMode: offlineMode ?? this.offlineMode,
      iataCode: iataCode ?? this.iataCode,
      backgroundModeEnabled: backgroundModeEnabled ?? this.backgroundModeEnabled,
      developerModeEnabled: developerModeEnabled ?? this.developerModeEnabled,
      mapStyle: mapStyle ?? this.mapStyle,
      closeAppAfterDisconnect: closeAppAfterDisconnect ?? this.closeAppAfterDisconnect,
      themeMode: themeMode ?? this.themeMode,
    );
  }

  /// Get power level display string (for main settings)
  String get powerLevelDisplay {
    return '${powerLevel.toStringAsFixed(1)} W';
  }

  /// Get power level display string with dBm (for selector dialog)
  String get powerLevelDisplayWithDbm {
    if (powerLevel == 0.3) return '≤22dBm (0.3W)';
    if (powerLevel == 0.6) return '28dBm (0.6W)';
    if (powerLevel == 1.0) return '30dBm (1.0W)';
    if (powerLevel == 2.0) return '33dBm (2.0W)';
    return '$powerLevel W';
  }

  /// Get auto-ping interval display string
  String get autoPingIntervalDisplay {
    if (autoPingInterval == 15) return '15 seconds';
    if (autoPingInterval == 30) return '30 seconds';
    if (autoPingInterval == 60) return '60 seconds';
    return '$autoPingInterval seconds';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is UserPreferences &&
        other.powerLevel == powerLevel &&
        other.txPower == txPower &&
        other.externalAntenna == externalAntenna &&
        other.externalAntennaSet == externalAntennaSet &&
        other.autoPingInterval == autoPingInterval &&
        other.ignoreCarpeater == ignoreCarpeater &&
        other.ignoreRepeaterId == ignoreRepeaterId &&
        other.autoPowerSet == autoPowerSet &&
        other.offlineMode == offlineMode &&
        other.iataCode == iataCode &&
        other.backgroundModeEnabled == backgroundModeEnabled &&
        other.developerModeEnabled == developerModeEnabled &&
        other.mapStyle == mapStyle &&
        other.closeAppAfterDisconnect == closeAppAfterDisconnect &&
        other.themeMode == themeMode;
  }

  @override
  int get hashCode {
    return Object.hash(
      powerLevel,
      txPower,
      externalAntenna,
      externalAntennaSet,
      autoPingInterval,
      ignoreCarpeater,
      ignoreRepeaterId,
      autoPowerSet,
      offlineMode,
      iataCode,
      backgroundModeEnabled,
      developerModeEnabled,
      mapStyle,
      closeAppAfterDisconnect,
      themeMode,
    );
  }
}

/// Power level options
class PowerLevel {
  static const double low = 0.3; // 22-24 dBm (standard devices)
  static const double medium = 0.6; // 28 dBm (Heltec V4 boosted)
  static const double high = 1.0; // 30 dBm (1W PA modules)
  static const double veryHigh = 2.0; // 33 dBm (2W PA modules)

  static const List<double> values = [low, medium, high, veryHigh];

  /// Get TX power in dBm for a given power level
  static int getTxPower(double powerLevel) {
    if (powerLevel == low) return 22;
    if (powerLevel == medium) return 28;
    if (powerLevel == high) return 30;
    if (powerLevel == veryHigh) return 33;
    return 22; // Default
  }
}

/// Auto-ping interval options
class AutoPingInterval {
  static const int fast = 15; // 15 seconds
  static const int normal = 30; // 30 seconds (default)
  static const int slow = 60; // 60 seconds

  static const List<int> values = [fast, normal, slow];
}
