import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../models/connection_state.dart';
import '../../models/device_model.dart';
import '../../utils/debug_logger_io.dart';
import '../bluetooth/bluetooth_service.dart';
import 'buffer_utils.dart';
import 'channel_service.dart';
import 'crypto_service.dart';
import 'packet_parser.dart';
import 'protocol_constants.dart';

/// Response from device query command
class DeviceQueryResponse {
  final int protocolVersion;
  final String manufacturer;
  final String? firmwareBuildDate; // Added in protocol v8

  const DeviceQueryResponse({
    required this.protocolVersion,
    required this.manufacturer,
    this.firmwareBuildDate,
  });
}

/// Response from AppStart/SelfInfo command
/// Contains device identity including public key
class SelfInfo {
  final int type;
  final int txPower;
  final int maxTxPower;
  final Uint8List publicKey;
  final String name;

  const SelfInfo({
    required this.type,
    required this.txPower,
    required this.maxTxPower,
    required this.publicKey,
    required this.name,
  });

  /// Get public key as hex string
  String get publicKeyHex => publicKey.map((b) => b.toRadixString(16).padLeft(2, '0')).join('').toUpperCase();
}

/// MeshCore connection manager
/// Ported from content/mc/connection/connection.js in WebClient repo
/// 
/// Implements the 10-step connection workflow:
/// 1. BLE GATT Connect
/// 2. Protocol Handshake
/// 3. Device Info Query
/// 4. Device Model Auto-Power Selection
/// 5. Time Sync
/// 6. API Capacity Check (slot acquisition)
/// 7. Channel Setup
/// 8. GPS Init
/// 9. Connected State
class MeshCoreConnection {
  final BluetoothService _bluetooth;
  final _stepController = StreamController<ConnectionStep>.broadcast();
  final _channelMessageController = StreamController<ChannelMessage>.broadcast();
  final _rawDataController = StreamController<Map<String, dynamic>>.broadcast();
  final _logRxDataController = StreamController<({Uint8List raw, double snr, int rssi})>.broadcast();
  final _controlDataController = StreamController<({Uint8List raw, double snr, int rssi})>.broadcast();
  final _noiseFloorController = StreamController<int>.broadcast();
  final _batteryController = StreamController<int>.broadcast();

  ConnectionStep _currentStep = ConnectionStep.disconnected;
  DeviceQueryResponse? _deviceInfo;
  DeviceModel? _deviceModel;
  ChannelInfo? _wardrivingChannel;
  StreamSubscription? _dataSubscription;

  // Completers for command responses
  Completer<DeviceQueryResponse>? _deviceQueryCompleter;
  Completer<SelfInfo>? _selfInfoCompleter;
  Completer<void>? _sentCompleter;
  Completer<ChannelInfo>? _channelInfoCompleter;
  Completer<int>? _statsCompleter;

  // Device self info (contains public key)
  SelfInfo? _selfInfo;

  // Callback for auth request during connection workflow (Step 6)
  // Set by AppStateProvider before calling connect()
  // Returns auth result map or null on failure
  Future<Map<String, dynamic>?> Function()? onRequestAuth;

  // Noise floor tracking
  int? _lastNoiseFloor; // dBm or null if not supported
  Timer? _noiseFloorTimer;

  // Battery tracking
  int? _lastBatteryMilliVolts; // millivolts or null if not supported
  Timer? _batteryTimer;

  MeshCoreConnection({required BluetoothService bluetooth}) : _bluetooth = bluetooth {
    _dataSubscription = _bluetooth.dataStream.listen(_onFrameReceived);
  }

  /// Stream of connection step changes
  Stream<ConnectionStep> get stepStream => _stepController.stream;

  /// Stream of channel messages (for RX pings)
  Stream<ChannelMessage> get channelMessageStream => _channelMessageController.stream;

  /// Stream of raw data pushes
  Stream<Map<String, dynamic>> get rawDataStream => _rawDataController.stream;

  /// Stream of LogRxData packets (for unified RX handler)
  Stream<({Uint8List raw, double snr, int rssi})> get logRxDataStream => _logRxDataController.stream;

  /// Stream of ControlData packets (for discovery responses)
  Stream<({Uint8List raw, double snr, int rssi})> get controlDataStream => _controlDataController.stream;

  /// Stream of noise floor updates (dBm)
  Stream<int> get noiseFloorStream => _noiseFloorController.stream;

  /// Stream of battery updates (percentage 0-100)
  Stream<int> get batteryStream => _batteryController.stream;

  /// Current connection step
  ConnectionStep get currentStep => _currentStep;

  /// Device info from query (null if not connected)
  DeviceQueryResponse? get deviceInfo => _deviceInfo;

  /// Matched device model (null if not connected or unknown)
  DeviceModel? get deviceModel => _deviceModel;

  /// Device self info including public key (null if not connected)
  SelfInfo? get selfInfo => _selfInfo;

  /// Device public key as hex string (null if not connected)
  String? get devicePublicKey => _selfInfo?.publicKeyHex;

  /// Last noise floor reading (dBm) or null if not supported/not connected
  int? get lastNoiseFloor => _lastNoiseFloor;

  /// Last battery percentage (0-100) or null if not supported/not connected
  int? get lastBatteryPercent => _lastBatteryMilliVolts != null
      ? _milliVoltsToPercent(_lastBatteryMilliVolts!)
      : null;

  /// Wardriving channel info (index, name, secret) - null if not connected
  ChannelInfo? get wardrivingChannel => _wardrivingChannel;

  /// Wardriving channel index (for TX tracking) - null if not connected
  int? get wardrivingChannelIndex => _wardrivingChannel?.channelIndex;

  /// Wardriving channel key (for message decryption) - null if not connected
  Uint8List? get wardrivingChannelKey => _wardrivingChannel?.secret;

  /// Wardriving channel hash (for echo correlation) - null if not connected
  int? get wardrivingChannelHash => _wardrivingChannel != null
      ? CryptoService.computeChannelHash(_wardrivingChannel!.secret)
      : null;

  void _updateStep(ConnectionStep step) {
    _currentStep = step;
    if (_stepController.isClosed) {
      debugError('[CONN] Cannot update step - controller is closed!');
      return;
    }
    debugLog('[CONN] Step: $step');
    _stepController.add(step);
  }

  /// Execute the full connection workflow
  /// Returns (deviceModel, autoPowerConfigured) for preferences update
  Future<({DeviceModel? deviceModel, bool autoPowerConfigured})> connect(String deviceId, List<DeviceModel> deviceModels) async {
    bool autoPowerConfigured = false;
    
    try {
      // Step 1: BLE Connect
      _updateStep(ConnectionStep.bleConnecting);
      await _bluetooth.connect(deviceId);

      // Step 2: Protocol Handshake (handled automatically by device)
      _updateStep(ConnectionStep.protocolHandshake);
      await Future.delayed(const Duration(milliseconds: 500));

      // Step 3: Device Query
      _updateStep(ConnectionStep.deviceQuery);
      _deviceInfo = await deviceQuery(ProtocolConstants.supportedCompanionProtocolVersion);

      // Step 3b: Get Self Info (contains public key)
      // This is critical for geo-auth API authentication
      try {
        _selfInfo = await getSelfInfo();
        debugLog('[CONN] Public key acquired: ${_selfInfo!.publicKeyHex.substring(0, 16)}...');
      } catch (e) {
        debugError('[CONN] Failed to get self info (public key): $e');
        // Public key is REQUIRED for geo-auth API
        throw Exception('Failed to acquire device public key: $e');
      }

      // Step 4: Power Configuration (auto-select based on device model)
      _updateStep(ConnectionStep.powerConfiguration);
      _deviceModel = _matchDeviceModel(_deviceInfo!.manufacturer, deviceModels);
      if (_deviceModel != null) {
        await setTxPower(_deviceModel!.txPower);
        autoPowerConfigured = true;
        debugLog('[CONN] Auto-configured power: ${_deviceModel!.power}W (${_deviceModel!.txPower}dBm) for ${_deviceModel!.shortName}');
      }

      // Step 5: Time Sync
      _updateStep(ConnectionStep.timeSync);
      await setDeviceTime(DateTime.now().millisecondsSinceEpoch ~/ 1000);

      // Step 6: API Session Acquisition (geo-auth)
      _updateStep(ConnectionStep.slotAcquisition);
      if (onRequestAuth != null) {
        debugLog('[CONN] Requesting API session via geo-auth');
        final authResult = await onRequestAuth!();
        if (authResult == null || authResult['success'] != true) {
          final reason = authResult?['reason'] ?? 'unknown';
          final message = authResult?['message'] ?? 'Authentication failed';
          debugError('[CONN] API session acquisition failed: $reason - $message');
          // Throw with reason code prefix for proper error handling
          throw Exception('AUTH_FAILED:$reason:$message');
        }
        debugLog('[CONN] API session acquired successfully (session_id: ${authResult['session_id']})');
      } else {
        debugLog('[CONN] No auth callback set, skipping API session acquisition');
      }

      // Step 7: Channel Setup
      _updateStep(ConnectionStep.channelSetup);
      debugLog('[CONN] Creating #wardriving channel');
      _wardrivingChannel = await ChannelService.ensureWardrivingChannel(this);
      debugLog('[CONN] Channel ready: ${_wardrivingChannel?.name ?? 'unknown'} (CH:${_wardrivingChannel?.channelIndex ?? -1})');

      // Step 8: GPS Init (handled externally)
      _updateStep(ConnectionStep.gpsInit);
      // GPS init is handled by GPS service

      // Step 9: Connected
      _updateStep(ConnectionStep.connected);
      debugLog('[CONN] Connection workflow complete');

      // Small delay to avoid BLE command collision
      await Future.delayed(const Duration(milliseconds: 200));

      // Start battery polling (30-second interval)
      _startBatteryPolling();

      // Start noise floor polling (5-second interval)
      // This may fail on older firmware (< v1.11.0)
      _startNoiseFloorPolling();

      return (deviceModel: _deviceModel, autoPowerConfigured: autoPowerConfigured);
    } catch (e) {
      debugError('[CONN] Connection failed: $e');
      _updateStep(ConnectionStep.error);
      // Clean up BLE connection on failure
      try {
        await _bluetooth.disconnect();
        debugLog('[CONN] Disconnected BLE after connection failure');
      } catch (disconnectError) {
        debugError('[CONN] Failed to disconnect after error: $disconnectError');
      }
      rethrow;
    }
  }

  /// Disconnect and cleanup
  /// Delete wardriving channel early (before stopping services)
  /// This should be called FIRST in the disconnect flow to ensure BLE is still connected
  Future<void> deleteWardrivingChannelEarly() async {
    if (_wardrivingChannel != null) {
      await ChannelService.deleteWardrivingChannel(this, _wardrivingChannel!.channelIndex);
      _wardrivingChannel = null;
    }
  }

  Future<void> disconnect() async {
    try {
      debugLog('[CONN] Disconnecting');

      // Stop noise floor polling
      _stopNoiseFloorPolling();

      // Stop battery polling
      _stopBatteryPolling();

      // Channel deletion happens early (before this method is called)
      // See deleteWardrivingChannelEarly() called from app_state_provider

      // Disconnect BLE
      await _bluetooth.disconnect();
      _deviceInfo = null;
      _deviceModel = null;
      _selfInfo = null;
      _lastNoiseFloor = null;
      _lastBatteryMilliVolts = null;
      _updateStep(ConnectionStep.disconnected);
      debugLog('[CONN] Disconnected successfully');
    } catch (e) {
      debugError('[CONN] Disconnect error: $e');
      _updateStep(ConnectionStep.disconnected);
    }
  }

  /// Match manufacturer string to device model
  /// Reference: parseDeviceModel() in wardrive.js
  DeviceModel? _matchDeviceModel(String manufacturer, List<DeviceModel> models) {
    // Strip build suffix (e.g., "nightly-e31c46f")
    final cleanManufacturer = manufacturer.split(' ').first;
    
    for (final model in models) {
      if (manufacturer.contains(model.manufacturer) ||
          cleanManufacturer.contains(model.manufacturer)) {
        return model;
      }
    }
    
    // Try partial match on short name
    for (final model in models) {
      if (manufacturer.toLowerCase().contains(model.shortName.toLowerCase())) {
        return model;
      }
    }
    
    return null;
  }

  /// Handle incoming frame from device
  void _onFrameReceived(Uint8List frame) {
    if (frame.isEmpty) return;

    try {
      debugLog('[CONN] Frame received (${frame.length} bytes): ${_hexDump(frame)}');
      
      final reader = BufferReader(frame);
      final responseCode = reader.readByte();
      
      debugLog('[CONN] Response code: 0x${responseCode.toRadixString(16).padLeft(2, '0')} ($responseCode)');

      switch (responseCode) {
        case ResponseCodes.ok:
          debugLog('[CONN] Received OK response');
          break;
        case ResponseCodes.err:
          final errorCode = reader.remainingBytesCount > 0 ? reader.readByte() : 0;
          debugLog('[CONN] Received ERR response (error code: $errorCode)');
          // Complete any pending completers with error
          final errException = Exception('Command error (code $errorCode)');
          _statsCompleter?.completeError(errException);
          _statsCompleter = null;
          _channelInfoCompleter?.completeError(errException);
          _channelInfoCompleter = null;
          _deviceQueryCompleter?.completeError(errException);
          _deviceQueryCompleter = null;
          break;
        case ResponseCodes.deviceInfo:
          _onDeviceInfoResponse(reader);
          break;
        case ResponseCodes.selfInfo:
          _onSelfInfoResponse(reader);
          break;
        case ResponseCodes.sent:
          _onSentResponse();
          break;
        case ResponseCodes.channelMsgRecv:
          _onChannelMsgRecvResponse(reader);
          break;
        case ResponseCodes.channelInfo:
          _onChannelInfoResponse(reader);
          break;
        case PushCodes.rawData:
          _onRawDataPush(reader);
          break;
        case PushCodes.logRxData:
          _onLogRxDataPush(reader);
          break;
        case PushCodes.controlData:
          _onControlDataPush(reader);
          break;
        case ResponseCodes.stats:
          _onStatsResponse(reader);
          break;
        case ResponseCodes.batteryVoltage:
          _onBatteryVoltageResponse(reader);
          break;
        default:
          // Log unhandled response codes (like JS implementation)
          debugLog('[CONN] Unhandled frame: code=$responseCode (0x${responseCode.toRadixString(16).padLeft(2, '0')})');
          break;
      }
    } catch (e, stack) {
      debugError('[CONN] Error processing frame (${frame.length} bytes): $e');
      debugError('[CONN] Frame hex: ${_hexDump(frame)}');
      debugError('[CONN] Stack trace: $stack');
    }
  }

  /// Helper to convert bytes to hex string for debugging
  String _hexDump(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  void _onDeviceInfoResponse(BufferReader reader) {
    // Protocol format changed in v7/v8:
    // v1-v6: protoVer (1) + manufacturer C-string (64) + publicKey (32)
    // v7+: firmwareVer (1) + reserved (6) + buildDate C-string (12) + manufacturerModel string (rest)
    // Note: Some v7 firmware (e.g., RAK4631) uses the new format

    final firmwareVer = reader.readByte();
    debugLog('[CONN] Firmware version: $firmwareVer');

    if (firmwareVer >= 7) {
      // Protocol v7+ format
      reader.readBytes(6); // skip reserved bytes
      final buildDate = reader.readCString(12); // e.g. "04-Jan-2026"
      final manufacturerModel = reader.readString(); // remainder of frame
      
      debugLog('[CONN] Build date: $buildDate');
      debugLog('[CONN] Manufacturer model: $manufacturerModel');
      
      final response = DeviceQueryResponse(
        protocolVersion: firmwareVer,
        manufacturer: manufacturerModel,
        firmwareBuildDate: buildDate,
      );
      
      _deviceQueryCompleter?.complete(response);
      _deviceQueryCompleter = null;
    } else {
      // Old protocol v1-v6 format
      final manufacturer = reader.readCString(64);
      reader.readBytes(32); // skip public key

      debugLog('[CONN] Manufacturer: $manufacturer');
      
      final response = DeviceQueryResponse(
        protocolVersion: firmwareVer,
        manufacturer: manufacturer,
      );
      
      _deviceQueryCompleter?.complete(response);
      _deviceQueryCompleter = null;
    }
  }

  void _onSelfInfoResponse(BufferReader reader) {
    // SelfInfo response format (from connection.js onSelfInfoResponse):
    // type (1 byte) + txPower (1 byte) + maxTxPower (1 byte) + publicKey (32 bytes)
    // + advLat (4 bytes) + advLon (4 bytes) + reserved (3 bytes) + manualAddContacts (1 byte)
    // + radioFreq (4 bytes) + radioBw (4 bytes) + radioSf (1 byte) + radioCr (1 byte)
    // + name (remaining bytes as string)
    try {
      final type = reader.readByte();
      final txPower = reader.readByte();
      final maxTxPower = reader.readByte();
      final publicKey = reader.readBytes(32);

      // Skip additional fields added in newer firmware versions
      // These fields exist between publicKey and name
      if (reader.remainingBytesCount >= 22) {
        reader.readInt32LE();  // advLat
        reader.readInt32LE();  // advLon
        reader.readBytes(3);   // reserved
        reader.readByte();     // manualAddContacts
        reader.readUInt32LE(); // radioFreq
        reader.readUInt32LE(); // radioBw
        reader.readByte();     // radioSf
        reader.readByte();     // radioCr
      }

      // Read name from remaining bytes
      final name = reader.hasMoreBytes ? reader.readString() : '';

      final selfInfo = SelfInfo(
        type: type,
        txPower: txPower,
        maxTxPower: maxTxPower,
        publicKey: publicKey,
        name: name,
      );

      _selfInfo = selfInfo;
      debugLog('[CONN] SelfInfo received: name="${selfInfo.name}", publicKey=${selfInfo.publicKeyHex.substring(0, 16)}...');

      _selfInfoCompleter?.complete(selfInfo);
      _selfInfoCompleter = null;
    } catch (e) {
      debugError('[CONN] Error parsing SelfInfo response: $e');
      _selfInfoCompleter?.completeError(e);
      _selfInfoCompleter = null;
    }
  }

  void _onSentResponse() {
    _sentCompleter?.complete();
    _sentCompleter = null;
  }

  void _onChannelMsgRecvResponse(BufferReader reader) {
    final channelIndex = reader.readByte();
    final senderTimestamp = reader.readUInt32LE();
    final snr = reader.readInt8() / 4.0;
    final rssi = reader.readInt8();
    final text = reader.readString();

    final message = ChannelMessage(
      channelIndex: channelIndex,
      senderTimestamp: senderTimestamp,
      snr: snr,
      rssi: rssi,
      text: text,
    );

    _channelMessageController.add(message);
  }

  void _onChannelInfoResponse(BufferReader reader) {
    final info = ChannelInfo.fromReader(reader);
    _channelInfoCompleter?.complete(info);
    _channelInfoCompleter = null;
  }

  void _onRawDataPush(BufferReader reader) {
    final snr = reader.readInt8() / 4.0;
    final rssi = reader.readInt8();
    reader.readByte(); // reserved
    final payload = reader.readRemainingBytes();

    _rawDataController.add({
      'snr': snr,
      'rssi': rssi,
      'payload': payload,
    });
  }

  void _onLogRxDataPush(BufferReader reader) {
    final snr = reader.readInt8() / 4.0;
    final rssi = reader.readInt8();
    final raw = reader.readRemainingBytes();

    // Broadcast to both legacy stream and new unified RX stream
    _rawDataController.add({
      'snr': snr,
      'rssi': rssi,
      'raw': raw,
    });

    _logRxDataController.add((raw: raw, snr: snr, rssi: rssi));
  }

  void _onControlDataPush(BufferReader reader) {
    final snr = reader.readInt8() / 4.0;
    final rssi = reader.readInt8();
    final raw = reader.readRemainingBytes();

    debugLog('[CONN] Received control data (discovery response): '
        '${raw.length} bytes, snr=$snr, rssi=$rssi');

    _controlDataController.add((raw: raw, snr: snr, rssi: rssi));
  }

  void _onStatsResponse(BufferReader reader) {
    // Stats response format (from web client):
    // <stats_type:1> <noise:int16> <last_rssi:int8> <last_snr:int8> <tx_air_secs:uint32> <rx_air_secs:uint32>
    try {
      final statsType = reader.readByte();
      if (statsType == StatsTypes.radio) {
        final noiseFloor = reader.readInt16LE();
        // Skip remaining fields (lastRssi, lastSnr, txAirSecs, rxAirSecs)
        _lastNoiseFloor = noiseFloor;
        _noiseFloorController.add(noiseFloor); // Emit to stream
        debugLog('[CONN] Noise floor updated: ${noiseFloor}dBm');
        _statsCompleter?.complete(noiseFloor);
      } else {
        debugLog('[CONN] Unknown stats type: $statsType');
        _statsCompleter?.complete(0);
      }
      _statsCompleter = null;
    } catch (e) {
      debugError('[CONN] Error parsing stats response: $e');
      _statsCompleter?.completeError(e);
      _statsCompleter = null;
    }
  }

  void _onBatteryVoltageResponse(BufferReader reader) {
    try {
      final milliVolts = reader.readUInt16LE();
      _lastBatteryMilliVolts = milliVolts;
      final percent = _milliVoltsToPercent(milliVolts);

      // Consume any remaining bytes (firmware may send extended format)
      if (reader.remainingBytesCount > 0) {
        final extraBytes = reader.readRemainingBytes();
        debugLog('[CONN] Battery response has ${extraBytes.length} extra bytes (ignoring)');
      }

      _batteryController.add(percent); // Emit percentage to stream
      debugLog('[CONN] Battery updated: ${milliVolts}mV ($percent%)');
    } catch (e) {
      debugError('[CONN] Error parsing battery response: $e');
    }
  }

  /// Convert battery millivolts to percentage (0-100)
  /// Typical LiPo range: 3.0V (empty) to 4.2V (full)
  int _milliVoltsToPercent(int milliVolts) {
    const minVoltage = 3000; // 3.0V = 0%
    const maxVoltage = 4200; // 4.2V = 100%
    final clamped = milliVolts.clamp(minVoltage, maxVoltage);
    return ((clamped - minVoltage) / (maxVoltage - minVoltage) * 100).round();
  }

  /// Write frame to device
  Future<void> _sendToRadio(BufferWriter data) async {
    await _bluetooth.write(data.toBytes());
  }

  // ============================================
  // Command Methods (ported from connection.js)
  // ============================================

  /// Send AppStart command to request SelfInfo
  /// Reference: sendCommandAppStart() in connection.js
  Future<void> sendCommandAppStart() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.appStart);
    data.writeByte(1); // appVer
    data.writeBytes(Uint8List(6)); // reserved (6 zero bytes)
    data.writeString('MeshMapper'); // appName
    await _sendToRadio(data);
  }

  /// Get device self info (includes public key)
  /// Reference: getSelfInfo() in connection.js
  Future<SelfInfo> getSelfInfo({Duration timeout = const Duration(seconds: 5)}) async {
    _selfInfoCompleter = Completer<SelfInfo>();

    // Save reference to future BEFORE sending command to avoid race condition
    final future = _selfInfoCompleter!.future;

    // Send AppStart command
    await sendCommandAppStart();

    // Wait for SelfInfo response
    return future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('getSelfInfo timed out'),
    );
  }

  /// Query device info
  Future<DeviceQueryResponse> deviceQuery(int appTargetVer) async {
    _deviceQueryCompleter = Completer<DeviceQueryResponse>();

    // Save reference to future BEFORE sending command to avoid race condition
    final future = _deviceQueryCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.deviceQuery);
    data.writeByte(appTargetVer);
    await _sendToRadio(data);

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Device query timed out'),
    );
  }

  /// Set device time
  Future<void> setDeviceTime(int epochSecs) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setDeviceTime);
    data.writeUInt32LE(epochSecs);
    await _sendToRadio(data);
  }

  /// Set TX power
  Future<void> setTxPower(int txPower) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setTxPower);
    data.writeByte(txPower);
    await _sendToRadio(data);
  }

  /// Set radio parameters
  Future<void> setRadioParams(int freq, int bw, int sf, int cr) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setRadioParams);
    data.writeUInt32LE(freq);
    data.writeUInt32LE(bw);
    data.writeByte(sf);
    data.writeByte(cr);
    await _sendToRadio(data);
  }

  /// Get channel info
  Future<ChannelInfo> getChannel(int channelIdx) async {
    debugLog('[CONN] getChannel($channelIdx) - sending request');
    _channelInfoCompleter = Completer<ChannelInfo>();

    // Save reference to future BEFORE writing command to avoid race condition
    // where response arrives and nulls completer before we can access the future
    final future = _channelInfoCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.getChannel);  // 31 (0x1F)
    data.writeByte(channelIdx);
    final bytes = data.toBytes();
    debugLog('[CONN] getChannel bytes: ${bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
    await _bluetooth.write(bytes);

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        debugLog('[CONN] getChannel($channelIdx) - TIMEOUT after 5s');
        throw TimeoutException('Get channel timed out');
      },
    );
  }

  /// Set channel
  Future<void> setChannel(int channelIdx, String name, Uint8List secret) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setChannel);
    data.writeByte(channelIdx);
    data.writeCString(name, 32);
    data.writeBytes(secret);
    await _sendToRadio(data);
  }

  /// Delete channel by setting it to empty
  Future<void> deleteChannel(int channelIdx) async {
    await setChannel(channelIdx, '', Uint8List(16));
  }

  /// Get all channels (queries until error)
  Future<List<ChannelInfo>> getChannels() async {
    final channels = <ChannelInfo>[];
    var channelIdx = 0;

    while (true) {
      try {
        final channel = await getChannel(channelIdx);
        channels.add(channel);
        channelIdx++;
      } catch (e) {
        // Stop when we get an error (no more channels)
        break;
      }
    }

    return channels;
  }

  /// Find channel by name (exact match)
  Future<ChannelInfo?> findChannelByName(String name) async {
    final channels = await getChannels();
    try {
      return channels.firstWhere((channel) => channel.name == name);
    } catch (e) {
      return null; // Not found
    }
  }

  /// Find channel by secret
  Future<ChannelInfo?> findChannelBySecret(Uint8List secret) async {
    final channels = await getChannels();
    try {
      return channels.firstWhere((channel) => _areBuffersEqual(channel.secret, secret));
    } catch (e) {
      return null; // Not found
    }
  }

  /// Helper to compare two byte arrays
  bool _areBuffersEqual(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  /// Send channel text message (for TX pings)
  /// Reference: sendCommandSendChannelTxtMsg in connection.js
  Future<void> sendChannelTextMessage(int txtType, int channelIdx, int senderTimestamp, String text) async {
    _sentCompleter = Completer<void>();

    // Save reference to future BEFORE sending command to avoid race condition
    final future = _sentCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.sendChannelTxtMsg);
    data.writeByte(txtType);
    data.writeByte(channelIdx);
    data.writeUInt32LE(senderTimestamp);
    data.writeString(text);
    await _sendToRadio(data);

    // Wait for sent confirmation (with timeout)
    await future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        // Ignore timeout - message may still be sent
      },
    );
  }

  /// Send ping to #wardriving channel
  /// Format: @[MapperBot] LAT, LON [power]
  /// Reference: buildPayload() in wardrive.js
  Future<void> sendPing(double lat, double lon, double powerWatts) async {
    if (_wardrivingChannel == null) {
      throw Exception('Wardriving channel not initialized');
    }

    // Format coordinates to 5 decimal places with comma separator
    final coordsStr = '${lat.toStringAsFixed(5)}, ${lon.toStringAsFixed(5)}';
    // Format power as "X.Xw" (e.g., "1.0w", "0.3w")
    final powerStr = '${powerWatts.toStringAsFixed(1)}w';
    final message = '@[MapperBot] $coordsStr [$powerStr]';

    debugLog('[CONN] Sending ping: $message');
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await sendChannelTextMessage(TxtTypes.plain, _wardrivingChannel!.channelIndex, timestamp, message);
  }

  /// Send discovery request to find nearby repeaters/rooms
  /// Reference: MeshCore discovery protocol
  ///
  /// Format:
  /// - Byte 0: CMD_SEND_CONTROL_DATA (0x37)
  /// - Byte 1: flags: DISCOVER_REQ (0x80)
  /// - Byte 2: type filter: REPEATER | ROOM (0x0C)
  /// - Bytes 3-6: random tag (4 bytes)
  /// - Bytes 7-10: timestamp = 0 (discover all)
  ///
  /// Returns the 4-byte tag used for matching responses
  Future<Uint8List> sendDiscoveryRequest() async {
    // Generate random 4-byte tag
    final random = Random.secure();
    final tag = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);

    debugLog('[CONN] Sending discovery request with tag: '
        '${tag.map((b) => b.toRadixString(16).padLeft(2, '0')).join('')}');

    final data = BufferWriter();
    data.writeByte(CommandCodes.sendControlData);     // 0x37
    data.writeByte(DiscoveryConstants.discoverReqFlag);  // 0x80 = DISCOVER_REQ
    data.writeByte(DiscoveryConstants.typeFilterRepeaterRoom);  // 0x0C = REPEATER | ROOM
    data.writeBytes(tag);                              // 4-byte random tag
    data.writeUInt32LE(0);                             // timestamp = 0 (discover all)
    await _sendToRadio(data);

    return tag;
  }

  /// Get battery voltage
  Future<void> getBatteryVoltage() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.getBatteryVoltage);
    await _sendToRadio(data);
  }

  /// Get radio statistics (noise floor)
  /// Reference: sendCommandGetStats in connection.js
  Future<int> getStats(int statsType) async {
    _statsCompleter = Completer<int>();

    // Save reference to future BEFORE sending command to avoid race condition
    final future = _statsCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.getStats);
    data.writeByte(statsType);
    await _sendToRadio(data);

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Get stats timed out'),
    );
  }

  /// Get noise floor (convenience method for getStats with Radio type)
  Future<int> getNoiseFloor() async {
    return await getStats(StatsTypes.radio);
  }

  /// Start periodic noise floor polling (5-second interval)
  /// Reference: noiseFloorUpdateTimer in wardrive.js
  void _startNoiseFloorPolling() {
    // Check if firmware supports noise floor (v1.11.0+)
    // For now, we'll try and handle errors gracefully
    _noiseFloorTimer?.cancel();

    // Get initial reading immediately
    _fetchNoiseFloor();

    _noiseFloorTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _fetchNoiseFloor();
    });

    debugLog('[CONN] Started noise floor polling (5s interval)');
  }

  Future<void> _fetchNoiseFloor() async {
    try {
      debugLog('[CONN] Fetching noise floor...');
      await getNoiseFloor();
    } catch (e) {
      // Firmware may not support noise floor - don't spam logs
      debugLog('[CONN] Noise floor fetch failed: $e');
      // Stop polling if consistently failing
      _stopNoiseFloorPolling();
    }
  }

  /// Stop noise floor polling
  void _stopNoiseFloorPolling() {
    _noiseFloorTimer?.cancel();
    _noiseFloorTimer = null;
    debugLog('[CONN] Stopped noise floor polling');
  }

  /// Start periodic battery polling (30-second interval)
  void _startBatteryPolling() {
    _batteryTimer?.cancel();

    // Get initial reading (with error handling)
    _fetchBattery();

    _batteryTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      await _fetchBattery();
    });

    debugLog('[CONN] Started battery polling (30s interval)');
  }

  Future<void> _fetchBattery() async {
    try {
      debugLog('[CONN] ⚡ Fetching battery voltage (poll triggered)...');
      await getBatteryVoltage();
    } catch (e) {
      debugWarn('[CONN] Battery voltage fetch failed: $e');
      // Don't stop polling - battery might become available
    }
  }

  /// Stop battery polling
  void _stopBatteryPolling() {
    _batteryTimer?.cancel();
    _batteryTimer = null;
    debugLog('[CONN] Stopped battery polling');
  }

  /// Reboot device
  Future<void> reboot() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.reboot);
    data.writeString('reboot');
    await _sendToRadio(data);
  }

  /// Dispose of resources
  void dispose() {
    _stopNoiseFloorPolling();
    _stopBatteryPolling();
    _dataSubscription?.cancel();
    _stepController.close();
    _channelMessageController.close();
    _rawDataController.close();
    _logRxDataController.close();
    _controlDataController.close();
    _noiseFloorController.close();
    _batteryController.close();
  }
}
