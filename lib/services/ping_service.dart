import 'dart:async';

import 'package:geolocator/geolocator.dart';

import '../models/connection_state.dart';
import '../models/ping_data.dart';
import 'api_queue_service.dart';
import 'gps_service.dart';
import 'meshcore/connection.dart';
import 'meshcore/packet_parser.dart';

/// Ping service for TX/RX ping orchestration
/// Ported from wardrive.js ping logic
/// 
/// TX Flow:
/// 1. Validate GPS lock, geofence (150km from Ottawa), 25m min distance
/// 2. Send @[MapperBot]<LAT LON>[power] to #wardriving channel
/// 3. Start 6-second RX listening window
/// 4. Post to API queue with type "TX"
/// 
/// RX Flow:
/// 1. Monitor #wardriving channel for {MESHTASTIC:[repeater_id]} packets
/// 2. Buffer RX pings per repeater (max 4/batch)
/// 3. After listening window, post to API queue with type "RX"
class PingService {
  static const Duration _rxListeningWindow = Duration(seconds: 6);
  static const Duration _autoPingCooldown = Duration(seconds: 6);

  final GpsService _gpsService;
  final MeshCoreConnection _connection;
  final ApiQueueService _apiQueue;
  final String _deviceId;

  PingStats _stats = const PingStats();
  DateTime? _lastTxTime;
  Timer? _rxWindowTimer;
  StreamSubscription? _channelMessageSubscription;
  
  // RX buffer during listening window
  final Map<String, List<RxPing>> _rxBuffer = {};
  
  // Auto-ping mode
  bool _autoPingEnabled = false;
  StreamSubscription? _positionSubscription;

  /// Callback for ping events
  void Function(TxPing)? onTxPing;
  void Function(RxPing)? onRxPing;
  void Function(PingStats)? onStatsUpdated;

  PingService({
    required GpsService gpsService,
    required MeshCoreConnection connection,
    required ApiQueueService apiQueue,
    required String deviceId,
  })  : _gpsService = gpsService,
        _connection = connection,
        _apiQueue = apiQueue,
        _deviceId = deviceId {
    // Listen for channel messages (RX pings)
    _channelMessageSubscription = _connection.channelMessageStream.listen(_onChannelMessage);
  }

  /// Get current ping statistics
  PingStats get stats => _stats;

  /// Check if auto-ping is enabled
  bool get autoPingEnabled => _autoPingEnabled;

  /// Check if we can send a TX ping now
  PingValidation canPing() {
    // Check connection
    if (_connection.currentStep != ConnectionStep.connected) {
      return PingValidation.notConnected;
    }

    // Check GPS status
    if (_gpsService.status != GpsStatus.locked) {
      if (_gpsService.status == GpsStatus.outsideGeofence) {
        return PingValidation.outsideGeofence;
      }
      return PingValidation.noGpsLock;
    }

    // Check GPS position
    final position = _gpsService.lastPosition;
    if (position == null) {
      return PingValidation.noGpsLock;
    }

    // Check geofence
    if (!_gpsService.isWithinGeofence(position)) {
      return PingValidation.outsideGeofence;
    }

    // Check minimum distance from last ping
    if (!_gpsService.canPingAtPosition(position)) {
      return PingValidation.tooCloseToLastPing;
    }

    // Check cooldown (6 seconds between pings)
    if (_lastTxTime != null) {
      final elapsed = DateTime.now().difference(_lastTxTime!);
      if (elapsed < _autoPingCooldown) {
        return PingValidation.cooldownActive;
      }
    }

    return PingValidation.valid;
  }

  /// Send a TX ping
  /// Returns true if ping was sent successfully
  Future<bool> sendTxPing() async {
    final validation = canPing();
    if (validation != PingValidation.valid) {
      return false;
    }

    final position = _gpsService.lastPosition!;
    final power = _connection.deviceModel?.txPower ?? 22;

    try {
      // Send ping via BLE
      await _connection.sendPing(position.latitude, position.longitude, power);

      // Mark ping time and position
      _lastTxTime = DateTime.now();
      _gpsService.markPingPosition(position);

      // Create TX ping record
      final txPing = TxPing(
        latitude: position.latitude,
        longitude: position.longitude,
        power: power,
        timestamp: DateTime.now(),
        deviceId: _deviceId,
      );

      // Add to API queue
      await _apiQueue.enqueueTx(
        latitude: position.latitude,
        longitude: position.longitude,
        power: power,
        deviceId: _deviceId,
      );

      // Start RX listening window
      _startRxListeningWindow(position);

      // Update stats
      _stats = _stats.copyWith(txCount: _stats.txCount + 1);
      onStatsUpdated?.call(_stats);
      onTxPing?.call(txPing);

      return true;
    } catch (e) {
      return false;
    }
  }

  /// Start the 6-second RX listening window after TX
  void _startRxListeningWindow(Position txPosition) {
    // Clear previous buffer
    _rxBuffer.clear();

    // Cancel previous timer
    _rxWindowTimer?.cancel();

    // Set timer for window end
    _rxWindowTimer = Timer(_rxListeningWindow, () {
      _endRxListeningWindow(txPosition);
    });
  }

  /// End RX listening window and flush buffer to API queue
  void _endRxListeningWindow(Position txPosition) {
    // Flush buffered RX pings to API queue
    for (final entry in _rxBuffer.entries) {
      for (final rxPing in entry.value) {
        _apiQueue.enqueueRx(
          latitude: txPosition.latitude,
          longitude: txPosition.longitude,
          repeaterId: rxPing.repeaterId,
          snr: rxPing.snr,
          rssi: rxPing.rssi,
          deviceId: _deviceId,
        );
      }
    }

    _rxBuffer.clear();
  }

  /// Handle incoming channel message (potential RX ping)
  void _onChannelMessage(ChannelMessage message) {
    // Only process during RX listening window
    if (_rxWindowTimer == null || !_rxWindowTimer!.isActive) return;

    // Check if this is a repeater echo
    if (!message.isRepeaterEcho) return;

    final repeaterId = message.repeaterId;
    if (repeaterId == null) return;

    // Create RX ping record
    final rxPing = RxPing(
      latitude: _gpsService.lastPosition?.latitude ?? 0,
      longitude: _gpsService.lastPosition?.longitude ?? 0,
      repeaterId: repeaterId,
      timestamp: DateTime.now(),
      snr: message.snr,
      rssi: message.rssi,
    );

    // Buffer RX ping (max 4 per repeater)
    if (!_rxBuffer.containsKey(repeaterId)) {
      _rxBuffer[repeaterId] = [];
    }
    if (_rxBuffer[repeaterId]!.length < 4) {
      _rxBuffer[repeaterId]!.add(rxPing);

      // Update stats
      _stats = _stats.copyWith(rxCount: _stats.rxCount + 1);
      onStatsUpdated?.call(_stats);
      onRxPing?.call(rxPing);
    }
  }

  /// Enable auto-ping mode
  void enableAutoPing() {
    if (_autoPingEnabled) return;
    
    _autoPingEnabled = true;

    // Listen for position updates and auto-ping when conditions are met
    _positionSubscription = _gpsService.positionStream.listen((position) async {
      if (!_autoPingEnabled) return;
      
      final validation = canPing();
      if (validation == PingValidation.valid) {
        await sendTxPing();
      }
    });
  }

  /// Disable auto-ping mode
  void disableAutoPing() {
    _autoPingEnabled = false;
    _positionSubscription?.cancel();
    _positionSubscription = null;
  }

  /// Reset statistics
  void resetStats() {
    _stats = const PingStats();
    onStatsUpdated?.call(_stats);
  }

  /// Dispose of resources
  void dispose() {
    _rxWindowTimer?.cancel();
    _channelMessageSubscription?.cancel();
    _positionSubscription?.cancel();
  }
}

/// Ping validation result
enum PingValidation {
  /// All conditions met, can ping
  valid,
  
  /// Not connected to device
  notConnected,
  
  /// No GPS lock
  noGpsLock,
  
  /// Outside geofence (150km from Ottawa)
  outsideGeofence,
  
  /// Too close to last ping (< 25m)
  tooCloseToLastPing,
  
  /// Cooldown period active (< 6s since last ping)
  cooldownActive,
}

extension PingValidationExtension on PingValidation {
  String get message {
    switch (this) {
      case PingValidation.valid:
        return 'Ready to ping';
      case PingValidation.notConnected:
        return 'Not connected to device';
      case PingValidation.noGpsLock:
        return 'Waiting for GPS lock';
      case PingValidation.outsideGeofence:
        return 'Outside service area (150km from Ottawa)';
      case PingValidation.tooCloseToLastPing:
        return 'Move 25m before next ping';
      case PingValidation.cooldownActive:
        return 'Wait 6 seconds between pings';
    }
  }
}
