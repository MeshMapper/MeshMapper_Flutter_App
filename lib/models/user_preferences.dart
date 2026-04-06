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

  /// Unit system for distances (metric, imperial)
  final String unitSystem;

  /// Hybrid mode enabled (alternates Active + Discovery pings)
  final bool hybridModeEnabled;

  /// Map auto-follow GPS position
  final bool mapAutoFollow;

  /// Map always north up (false = rotate with heading)
  final bool mapAlwaysNorth;

  /// Map rotation lock (disable rotation gestures)
  final bool mapRotationLocked;

  /// Disable RSSI carpeater filter (allow all signal strengths)
  final bool disableRssiFilter;

  /// Anonymous mode: rename companion to "Anonymous" during wardriving
  final bool anonymousMode;

  /// Discovery drop: count failed discoveries as failed pings and report to API
  final bool discDropEnabled;

  /// Delete wardriving channel from radio on disconnect
  final bool deleteChannelOnDisconnect;

  /// Minimum ping distance in meters (25m floor, user can increase)
  final int minPingDistanceMeters;

  /// Auto-stop auto-ping after 30 minutes of idle (no movement)
  final bool autoStopAfterIdle;

  /// Show top 3 repeaters by SNR on the map during wardriving
  final bool showTopRepeaters;

  /// Coverage marker style on the map (dot, pin, diamond)
  final String markerStyle;

  /// GPS position marker style (arrow, car, bike, boat, walk)
  final String gpsMarkerStyle;

  /// Color vision type for accessibility (none, protanopia, deuteranopia, tritanopia, achromatopsia)
  final String colorVisionType;

  /// Download map tiles (base map + coverage overlay). When false, no tile network requests are made to save mobile data.
  final bool mapTilesEnabled;

  /// Disconnect alert: play audible alert when pinging stops unexpectedly (BLE disconnect, idle timeout, maintenance)
  final bool disconnectAlertEnabled;

  /// Custom API endpoint enabled (forwards wardrive payload to third-party URL)
  final bool customApiEnabled;

  /// Custom API endpoint URL (must be HTTPS)
  final String? customApiUrl;

  /// Custom API endpoint key (sent as X-API-Key header)
  final String? customApiKey;

  /// Whether the user has accepted the third-party data sharing disclaimer
  final bool customApiDisclaimerAccepted;

  /// Include device public key prefix in custom API payload (contact field)
  final bool customApiIncludeContact;

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
    this.unitSystem = 'metric',
    this.hybridModeEnabled = true,
    this.mapAutoFollow = false,
    this.mapAlwaysNorth = true,
    this.mapRotationLocked = false,
    this.disableRssiFilter = false,
    this.anonymousMode = false,
    this.discDropEnabled = false,
    this.deleteChannelOnDisconnect = true,
    this.minPingDistanceMeters = 25,
    this.autoStopAfterIdle = true,
    this.showTopRepeaters = false,
    this.markerStyle = 'dot',
    this.gpsMarkerStyle = 'arrow',
    this.colorVisionType = 'none',
    this.mapTilesEnabled = true,
    this.disconnectAlertEnabled = false,
    this.customApiEnabled = false,
    this.customApiUrl,
    this.customApiKey,
    this.customApiDisclaimerAccepted = false,
    this.customApiIncludeContact = true,
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
      unitSystem: (json['unitSystem'] as String?) ?? 'metric',
      hybridModeEnabled: (json['hybridModeEnabled'] as bool?) ?? true,
      mapAutoFollow: (json['mapAutoFollow'] as bool?) ?? false,
      mapAlwaysNorth: (json['mapAlwaysNorth'] as bool?) ?? true,
      mapRotationLocked: (json['mapRotationLocked'] as bool?) ?? false,
      disableRssiFilter: (json['disableRssiFilter'] as bool?) ?? false,
      anonymousMode: (json['anonymousMode'] as bool?) ?? false,
      discDropEnabled: (json['discDropEnabled'] as bool?) ?? false,
      deleteChannelOnDisconnect: (json['deleteChannelOnDisconnect'] as bool?) ?? true,
      minPingDistanceMeters: (json['minPingDistanceMeters'] as int?) ?? 25,
      autoStopAfterIdle: (json['autoStopAfterIdle'] as bool?) ?? true,
      showTopRepeaters: (json['showTopRepeaters'] as bool?) ?? false,
      markerStyle: (json['markerStyle'] as String?) ?? 'dot',
      gpsMarkerStyle: (json['gpsMarkerStyle'] as String?) ?? 'arrow',
      colorVisionType: (json['colorVisionType'] as String?) ?? 'none',
      mapTilesEnabled: (json['mapTilesEnabled'] as bool?) ?? true,
      disconnectAlertEnabled: (json['disconnectAlertEnabled'] as bool?) ?? false,
      customApiEnabled: (json['customApiEnabled'] as bool?) ?? false,
      customApiUrl: json['customApiUrl'] as String?,
      customApiKey: json['customApiKey'] as String?,
      customApiDisclaimerAccepted: (json['customApiDisclaimerAccepted'] as bool?) ?? false,
      customApiIncludeContact: (json['customApiIncludeContact'] as bool?) ?? true,
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
      'unitSystem': unitSystem,
      'hybridModeEnabled': hybridModeEnabled,
      'mapAutoFollow': mapAutoFollow,
      'mapAlwaysNorth': mapAlwaysNorth,
      'mapRotationLocked': mapRotationLocked,
      'disableRssiFilter': disableRssiFilter,
      'anonymousMode': anonymousMode,
      'discDropEnabled': discDropEnabled,
      'deleteChannelOnDisconnect': deleteChannelOnDisconnect,
      'minPingDistanceMeters': minPingDistanceMeters,
      'autoStopAfterIdle': autoStopAfterIdle,
      'showTopRepeaters': showTopRepeaters,
      'markerStyle': markerStyle,
      'gpsMarkerStyle': gpsMarkerStyle,
      'colorVisionType': colorVisionType,
      'mapTilesEnabled': mapTilesEnabled,
      'disconnectAlertEnabled': disconnectAlertEnabled,
      'customApiEnabled': customApiEnabled,
      'customApiUrl': customApiUrl,
      'customApiKey': customApiKey,
      'customApiDisclaimerAccepted': customApiDisclaimerAccepted,
      'customApiIncludeContact': customApiIncludeContact,
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
    String? unitSystem,
    bool? hybridModeEnabled,
    bool? mapAutoFollow,
    bool? mapAlwaysNorth,
    bool? mapRotationLocked,
    bool? disableRssiFilter,
    bool? anonymousMode,
    bool? discDropEnabled,
    bool? deleteChannelOnDisconnect,
    int? minPingDistanceMeters,
    bool? autoStopAfterIdle,
    bool? showTopRepeaters,
    String? markerStyle,
    String? gpsMarkerStyle,
    String? colorVisionType,
    bool? mapTilesEnabled,
    bool? disconnectAlertEnabled,
    bool? customApiEnabled,
    String? customApiUrl,
    String? customApiKey,
    bool? customApiDisclaimerAccepted,
    bool? customApiIncludeContact,
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
      unitSystem: unitSystem ?? this.unitSystem,
      hybridModeEnabled: hybridModeEnabled ?? this.hybridModeEnabled,
      mapAutoFollow: mapAutoFollow ?? this.mapAutoFollow,
      mapAlwaysNorth: mapAlwaysNorth ?? this.mapAlwaysNorth,
      mapRotationLocked: mapRotationLocked ?? this.mapRotationLocked,
      disableRssiFilter: disableRssiFilter ?? this.disableRssiFilter,
      anonymousMode: anonymousMode ?? this.anonymousMode,
      discDropEnabled: discDropEnabled ?? this.discDropEnabled,
      deleteChannelOnDisconnect: deleteChannelOnDisconnect ?? this.deleteChannelOnDisconnect,
      minPingDistanceMeters: minPingDistanceMeters ?? this.minPingDistanceMeters,
      autoStopAfterIdle: autoStopAfterIdle ?? this.autoStopAfterIdle,
      showTopRepeaters: showTopRepeaters ?? this.showTopRepeaters,
      markerStyle: markerStyle ?? this.markerStyle,
      gpsMarkerStyle: gpsMarkerStyle ?? this.gpsMarkerStyle,
      colorVisionType: colorVisionType ?? this.colorVisionType,
      mapTilesEnabled: mapTilesEnabled ?? this.mapTilesEnabled,
      disconnectAlertEnabled: disconnectAlertEnabled ?? this.disconnectAlertEnabled,
      customApiEnabled: customApiEnabled ?? this.customApiEnabled,
      customApiUrl: customApiUrl ?? this.customApiUrl,
      customApiKey: customApiKey ?? this.customApiKey,
      customApiDisclaimerAccepted: customApiDisclaimerAccepted ?? this.customApiDisclaimerAccepted,
      customApiIncludeContact: customApiIncludeContact ?? this.customApiIncludeContact,
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

  /// Get min ping distance display string
  String get minPingDistanceDisplay => '${minPingDistanceMeters}m';

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
        other.themeMode == themeMode &&
        other.unitSystem == unitSystem &&
        other.hybridModeEnabled == hybridModeEnabled &&
        other.mapAutoFollow == mapAutoFollow &&
        other.mapAlwaysNorth == mapAlwaysNorth &&
        other.mapRotationLocked == mapRotationLocked &&
        other.disableRssiFilter == disableRssiFilter &&
        other.anonymousMode == anonymousMode &&
        other.discDropEnabled == discDropEnabled &&
        other.deleteChannelOnDisconnect == deleteChannelOnDisconnect &&
        other.minPingDistanceMeters == minPingDistanceMeters &&
        other.autoStopAfterIdle == autoStopAfterIdle &&
        other.showTopRepeaters == showTopRepeaters &&
        other.markerStyle == markerStyle &&
        other.gpsMarkerStyle == gpsMarkerStyle &&
        other.colorVisionType == colorVisionType &&
        other.mapTilesEnabled == mapTilesEnabled &&
        other.disconnectAlertEnabled == disconnectAlertEnabled &&
        other.customApiEnabled == customApiEnabled &&
        other.customApiUrl == customApiUrl &&
        other.customApiKey == customApiKey &&
        other.customApiDisclaimerAccepted == customApiDisclaimerAccepted &&
        other.customApiIncludeContact == customApiIncludeContact;
  }

  @override
  int get hashCode {
    return Object.hashAll([
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
      unitSystem,
      hybridModeEnabled,
      mapAutoFollow,
      mapAlwaysNorth,
      mapRotationLocked,
      disableRssiFilter,
      anonymousMode,
      discDropEnabled,
      deleteChannelOnDisconnect,
      minPingDistanceMeters,
      autoStopAfterIdle,
      showTopRepeaters,
      markerStyle,
      gpsMarkerStyle,
      colorVisionType,
      mapTilesEnabled,
      disconnectAlertEnabled,
      customApiEnabled,
      customApiUrl,
      customApiKey,
      customApiDisclaimerAccepted,
      customApiIncludeContact,
    ]);
  }

  /// Check if using imperial units
  bool get isImperial => unitSystem == 'imperial';
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

/// Minimum ping distance (meters)
class MinPingDistance {
  static const int min = 25;
}
