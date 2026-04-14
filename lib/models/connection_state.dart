/// Connection status for Bluetooth devices
enum ConnectionStatus {
  /// Not connected to any device
  disconnected,

  /// Currently scanning for devices
  scanning,

  /// Connecting to device
  connecting,

  /// Connected and ready
  connected,

  /// Connection error occurred
  error,
}

/// Connection workflow step (10-step sequence from WebClient)
/// Reference: DEVELOPMENT.md
enum ConnectionStep {
  /// Initial disconnected state
  disconnected,

  /// Auto-reconnecting after unexpected BLE disconnect
  reconnecting,

  /// Step 1: BLE GATT connect
  bleConnecting,

  /// Step 2: Protocol handshake
  protocolHandshake,

  /// Step 3: Device info query
  deviceQuery,

  /// Step 4: Device identification (match device model for display/reporting)
  powerConfiguration,

  /// Step 5: Time synchronization
  timeSync,

  /// Step 6: API slot acquisition
  slotAcquisition,

  /// Step 7: Channel setup (#wardriving)
  channelSetup,

  /// Step 8: GPS initialization
  gpsInit,

  /// Step 9: Fully connected and ready
  connected,

  /// Error state
  error,
}

/// GPS status indicators
enum GpsStatus {
  /// GPS permissions not granted
  permissionDenied,

  /// GPS is disabled on device
  disabled,

  /// Searching for GPS signal
  searching,

  /// GPS lock acquired
  locked,

  /// Outside service area
  /// Note: This state is reserved for future use with dynamic zone boundaries
  /// Zone validation is now handled server-side by the API
  outsideGeofence,
}

/// Extension methods for ConnectionStep
extension ConnectionStepExtension on ConnectionStep {
  /// Human-readable description of the step
  String get description {
    switch (this) {
      case ConnectionStep.disconnected:
        return 'Disconnected';
      case ConnectionStep.reconnecting:
        return 'Reconnecting...';
      case ConnectionStep.bleConnecting:
        return 'Connecting to device...';
      case ConnectionStep.protocolHandshake:
        return 'Protocol handshake...';
      case ConnectionStep.deviceQuery:
        return 'Querying device info...';
      case ConnectionStep.powerConfiguration:
        return 'Identifying device...';
      case ConnectionStep.timeSync:
        return 'Syncing time...';
      case ConnectionStep.slotAcquisition:
        return 'Acquiring API slot...';
      case ConnectionStep.channelSetup:
        return 'Setting up channel...';
      case ConnectionStep.gpsInit:
        return 'Initializing GPS...';
      case ConnectionStep.connected:
        return 'Connected';
      case ConnectionStep.error:
        return 'Connection error';
    }
  }

  /// Step number (1-9 for active steps)
  int get stepNumber {
    switch (this) {
      case ConnectionStep.disconnected:
        return 0;
      case ConnectionStep.reconnecting:
        return 0;
      case ConnectionStep.bleConnecting:
        return 1;
      case ConnectionStep.protocolHandshake:
        return 2;
      case ConnectionStep.deviceQuery:
        return 3;
      case ConnectionStep.powerConfiguration:
        return 4;
      case ConnectionStep.timeSync:
        return 5;
      case ConnectionStep.slotAcquisition:
        return 6;
      case ConnectionStep.channelSetup:
        return 7;
      case ConnectionStep.gpsInit:
        return 8;
      case ConnectionStep.connected:
        return 9;
      case ConnectionStep.error:
        return -1;
    }
  }

  /// Total steps in workflow (excluding error)
  static int get totalSteps => 9;
}
