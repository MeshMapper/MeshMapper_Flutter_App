import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import '../../models/connection_state.dart';
import '../../models/device_model.dart';
import '../../utils/debug_logger_io.dart';
import '../transport/companion_transport.dart';
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
  final String?
      firmwareVersionString; // e.g. "v1.14.0-9f1a3ea" (v7+, 20-byte C-string)
  final int?
      pathHashMode; // 0=1-byte, 1=2-byte, 2=3-byte (null if old firmware, v10+)

  const DeviceQueryResponse({
    required this.protocolVersion,
    required this.manufacturer,
    this.firmwareBuildDate,
    this.firmwareVersionString,
    this.pathHashMode,
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

  /// Radio configuration reported in the SelfInfo response (newer firmware only;
  /// null on older firmware that omits the radio block). Encoding as sent by the device:
  /// frequency in kHz, bandwidth in Hz, SF/CR raw. (The companion-protocol wiki documents
  /// freq as Hz, but real hardware reports kHz — a 910.525 MHz radio sends 910525.)
  final int? radioFreqKHz;
  final int? radioBwHz;
  final int? radioSf;
  final int? radioCr;

  const SelfInfo({
    required this.type,
    required this.txPower,
    required this.maxTxPower,
    required this.publicKey,
    required this.name,
    this.radioFreqKHz,
    this.radioBwHz,
    this.radioSf,
    this.radioCr,
  });

  /// Get public key as hex string
  String get publicKeyHex => publicKey
      .map((b) => b.toRadixString(16).padLeft(2, '0'))
      .join('')
      .toUpperCase();

  /// Whether the device reported a usable radio configuration.
  bool get hasRadioConfig => radioFreqKHz != null && radioFreqKHz! > 0;

  /// Compact radio config for the API: "freqMHz,bwKHz,SF,CR" (e.g. "910.525,62.5,7,5").
  /// Frequency kHz→MHz (÷1000), bandwidth Hz→kHz (÷1000). Null when no radio params.
  String? get radioConfigApi {
    if (!hasRadioConfig) return null;
    final freq = _trimNum(radioFreqKHz! / 1e3);
    final bw = _trimNum((radioBwHz ?? 0) / 1e3);
    return '$freq,$bw,${radioSf ?? 0},${radioCr ?? 0}';
  }

  /// Human-readable radio config for the UI: "910.525 MHz · 62.5 kHz · SF7 · CR5".
  /// Null when unavailable.
  String? get radioConfigDisplay {
    if (!hasRadioConfig) return null;
    final freq = _trimNum(radioFreqKHz! / 1e3);
    final bw = _trimNum((radioBwHz ?? 0) / 1e3);
    return '$freq MHz · $bw kHz · SF${radioSf ?? 0} · CR${radioCr ?? 0}';
  }

  /// Format a number with up to 3 decimals, trimming trailing zeros and a trailing dot
  /// (910.525 → "910.525", 62.5 → "62.5", 915.0 → "915").
  static String _trimNum(double v) {
    var s = v.toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '').replaceAll(RegExp(r'\.$'), '');
    }
    return s;
  }
}

/// Thrown by [MeshCoreConnection.sign] for protocol-level sign failures.
///
/// [code] is stable and is what callers branch on:
/// * `unsupported`          — the radio answered CMD_SIGN_START with ERR (old firmware)
/// * `data_too_long`        — payload exceeds the radio's `maxSignDataLen`
/// * `malformed_response`   — a truncated RESP_SIGN_START / RESP_SIGNATURE frame
/// * `bad_signature_length` — the radio returned something other than 64 bytes
/// * `err`                  — the radio answered ERR mid-sign
/// * `aborted`              — the connection closed while a sign was in flight
class SignException implements Exception {
  final String code;
  final String message;

  const SignException(this.code, this.message);

  @override
  String toString() => 'SignException($code): $message';
}

/// MeshCore connection manager
/// Ported from content/mc/connection/connection.js in WebClient repo
///
/// Implements the 10-step connection workflow:
/// 1. BLE GATT Connect
/// 2. Protocol Handshake
/// 3. Device Info Query
/// 4. Device Identification (match device model for display/reporting)
/// 5. Time Sync
/// 6. API Capacity Check (slot acquisition)
/// 7. Channel Setup
/// 8. GPS Init
/// 9. Connected State
class MeshCoreConnection {
  final CompanionTransport _transport;
  bool _disposed = false;
  final _stepController = StreamController<ConnectionStep>.broadcast();
  final _channelMessageController =
      StreamController<ChannelMessage>.broadcast();
  final _rawDataController = StreamController<Map<String, dynamic>>.broadcast();
  final _logRxDataController =
      StreamController<({Uint8List raw, double snr, int rssi})>.broadcast();
  final _controlDataController =
      StreamController<({Uint8List raw, double snr, int rssi})>.broadcast();
  final _traceDataController = StreamController<Uint8List>.broadcast();
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
  Completer<void>? _setTimeCompleter;
  Completer<ChannelInfo>? _channelInfoCompleter;
  Completer<int>? _statsCompleter;
  Completer<String>? _exportContactCompleter;
  Completer<int>? _getTimeCompleter;

  // CMD_SIGN state. `_signGate` is non-null for the whole duration of a sign;
  // Task-4's write funnel queues every non-sign frame behind it so no other
  // command's OK can be mistaken for a per-chunk sign ack.
  bool _signInProgress = false;
  Completer<int>? _signStartCompleter; // resolves with maxSignDataLen
  Completer<void>? _signChunkOkCompleter; // resolves on each chunk's OK
  Completer<Uint8List>? _signatureCompleter; // resolves with the 64-byte sig
  Completer<void>? _signGate;

  // Device self info (contains public key)
  SelfInfo? _selfInfo;

  // Callback for auth request during connection workflow (Step 6)
  // Set by AppStateProvider before calling connect()
  // Returns auth result map or null on failure
  Future<Map<String, dynamic>?> Function()? onRequestAuth;

  // Noise floor tracking
  int? _lastNoiseFloor; // dBm or null if not supported
  Timer? _noiseFloorTimer;
  bool _isFetchingNoiseFloor = false;
  int _noiseFloorFailCount = 0;

  // Battery tracking
  int? _lastBatteryMilliVolts; // millivolts or null if not supported
  Timer? _batteryTimer;

  MeshCoreConnection({required CompanionTransport transport})
      : _transport = transport {
    _dataSubscription = _transport.dataStream.listen(_onFrameReceived);
  }

  /// Stream of connection step changes
  Stream<ConnectionStep> get stepStream => _stepController.stream;

  /// Stream of channel messages (for RX pings)
  Stream<ChannelMessage> get channelMessageStream =>
      _channelMessageController.stream;

  /// Stream of raw data pushes
  Stream<Map<String, dynamic>> get rawDataStream => _rawDataController.stream;

  /// Stream of LogRxData packets (for unified RX handler)
  Stream<({Uint8List raw, double snr, int rssi})> get logRxDataStream =>
      _logRxDataController.stream;

  /// Stream of ControlData packets (for discovery responses)
  Stream<({Uint8List raw, double snr, int rssi})> get controlDataStream =>
      _controlDataController.stream;

  /// Stream of TraceData packets (for trace path responses)
  /// 0x89 has NO snr/rssi prefix — raw bytes are the trace payload directly
  Stream<Uint8List> get traceDataStream => _traceDataController.stream;

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
  int? get lastBatteryPercent {
    final mv = _lastBatteryMilliVolts;
    return mv != null ? _milliVoltsToPercent(mv) : null;
  }

  /// Wardriving channel info (index, name, secret) - null if not connected
  ChannelInfo? get wardrivingChannel => _wardrivingChannel;

  /// Wardriving channel index (for TX tracking) - null if not connected
  int? get wardrivingChannelIndex => _wardrivingChannel?.channelIndex;

  /// Wardriving channel key (for message decryption) - null if not connected
  Uint8List? get wardrivingChannelKey => _wardrivingChannel?.secret;

  /// Wardriving channel hash (for echo correlation) - null if not connected
  int? get wardrivingChannelHash {
    final channel = _wardrivingChannel;
    return channel != null
        ? CryptoService.computeChannelHash(channel.secret)
        : null;
  }

  void _updateStep(ConnectionStep step) {
    _currentStep = step;
    if (_disposed || _stepController.isClosed) {
      debugLog(
          '[CONN] Ignoring step update on disposed connection (expected during reconnect)');
      return;
    }
    debugLog('[CONN] Step: $step');
    _stepController.add(step);
  }

  /// Execute the full connection workflow
  /// Returns (deviceModel, deviceModelMatched) for display/reporting purposes
  /// Note: This method does NOT modify radio TX power settings - it only reads device info
  Future<({DeviceModel? deviceModel, bool deviceModelMatched})> connect(
      List<DeviceModel> deviceModels) async {
    if (_disposed) {
      throw Exception('Connection instance has been disposed');
    }
    bool deviceModelMatched = false;

    try {
      // Step 1: Transport connect (already connected by caller)
      _updateStep(ConnectionStep.transportConnecting);

      // Step 2: Protocol Handshake (handled automatically by device)
      _updateStep(ConnectionStep.protocolHandshake);
      await Future.delayed(const Duration(milliseconds: 500));

      // Step 3: Device Query
      _updateStep(ConnectionStep.deviceQuery);
      _deviceInfo = await deviceQuery(
          ProtocolConstants.supportedCompanionProtocolVersion);

      // Step 3b: Get Self Info (contains public key)
      // This is critical for geo-auth API authentication
      try {
        _selfInfo = await getSelfInfo();
        final pubKeyHex = _selfInfo?.publicKeyHex;
        if (pubKeyHex == null) {
          throw Exception('getSelfInfo() returned null public key');
        }
        debugLog(
            '[CONN] Public key acquired: ${pubKeyHex.substring(0, 16)}...');
      } catch (e) {
        debugError('[CONN] Failed to get self info (public key): $e');
        // Public key is REQUIRED for geo-auth API
        throw Exception('Failed to acquire device public key: $e');
      }

      // Step 4: Device Identification (match device model for display/reporting purposes)
      // Note: We do NOT modify the radio's TX power - we only read device info
      _updateStep(ConnectionStep.powerConfiguration);
      final deviceInfo = _deviceInfo;
      if (deviceInfo == null) throw Exception('Device query returned null');
      _deviceModel = _matchDeviceModel(deviceInfo.manufacturer, deviceModels);
      final matchedModel = _deviceModel;
      if (matchedModel != null) {
        deviceModelMatched = true;
        debugLog(
            '[CONN] Device identified: ${matchedModel.shortName} (reports ${matchedModel.power}W / ${matchedModel.txPower}dBm)');
      } else {
        debugLog(
            '[CONN] Device model not recognized - user must manually select power level for reporting');
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
          debugError(
              '[CONN] API session acquisition failed: $reason - $message');
          // Throw with reason code prefix for proper error handling
          throw Exception('AUTH_FAILED:$reason:$message');
        }
        debugLog(
            '[CONN] API session acquired successfully (session_id: ${authResult['session_id']})');
      } else {
        debugLog(
            '[CONN] No auth callback set, skipping API session acquisition');
      }

      // Guard: transport may have disconnected during the async auth API call
      if (_disposed ||
          _transport.connectionStatus != ConnectionStatus.connected) {
        throw Exception(
            'Transport disconnected during authentication. Please try connecting again.');
      }

      // Step 7: Channel Setup
      _updateStep(ConnectionStep.channelSetup);
      debugLog('[CONN] Creating #wardriving channel');
      _wardrivingChannel = await ChannelService.ensureWardrivingChannel(this);
      debugLog(
          '[CONN] Channel ready: ${_wardrivingChannel?.name ?? 'unknown'} (CH:${_wardrivingChannel?.channelIndex ?? -1})');

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

      return (
        deviceModel: _deviceModel,
        deviceModelMatched: deviceModelMatched
      );
    } catch (e) {
      debugError('[CONN] Connection failed: $e');
      _updateStep(ConnectionStep.error);
      // Clean up BLE connection on failure
      try {
        await _transport.disconnect();
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
    // Channel deletion is a gated write; a live sign would park it behind the
    // sign timeout while BLE is still up. Abort the sign first.
    _abortPendingSign();
    final channel = _wardrivingChannel;
    if (channel != null) {
      await ChannelService.deleteWardrivingChannel(this, channel.channelIndex);
      _wardrivingChannel = null;
    }
  }

  Future<void> disconnect() async {
    try {
      debugLog('[CONN] Disconnecting');
      _abortPendingSign();

      // Stop noise floor polling
      _stopNoiseFloorPolling();

      // Stop battery polling
      _stopBatteryPolling();

      // Channel deletion happens early (before this method is called)
      // See deleteWardrivingChannelEarly() called from app_state_provider

      // Disconnect BLE
      await _transport.disconnect();
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
  DeviceModel? _matchDeviceModel(
      String manufacturer, List<DeviceModel> models) {
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

    // A RESP_SIGNATURE payload is 64 bytes of Ed25519 signature over the
    // portal's login nonce, and debug logs are uploadable to the bug-report
    // endpoint — so this one frame is logged by length only, never as hex.
    // Every other frame keeps the full hexdump.
    final frameDump = frame[0] == ResponseCodes.signature
        ? 'SIGNATURE payload redacted'
        : _hexDump(frame);

    try {
      debugLog('[CONN] Frame received (${frame.length} bytes): $frameDump');

      final reader = BufferReader(frame);
      final responseCode = reader.readByte();

      debugLog(
          '[CONN] Response code: 0x${responseCode.toRadixString(16).padLeft(2, '0')} ($responseCode)');

      switch (responseCode) {
        case ResponseCodes.ok:
          {
            debugLog('[CONN] Received OK response');
            // A pending sign owns the bare OK. The write gate keeps every
            // OK-emitting command *issued during* the sign off the wire, but it
            // cannot recall one that was already awaiting its OK when the sign
            // began. That is safe only because the sole other bare-OK consumer
            // is setDeviceTime, which runs once during connect().
            final signOk = _signChunkOkCompleter;
            if (signOk != null) {
              _signChunkOkCompleter = null;
              if (!signOk.isCompleted) signOk.complete();
              break;
            }
            _setTimeCompleter?.complete();
            _setTimeCompleter = null;
            break;
          }
        case ResponseCodes.err:
          final errorCode =
              reader.remainingBytesCount > 0 ? reader.readByte() : 0;
          debugLog('[CONN] Received ERR response (error code: $errorCode)');
          // A pending sign owns this ERR: the write gate has queued every other
          // command, so nothing else can be in flight. Without this the
          // old-firmware feature detect hangs for the full sign timeout.
          if (_failPendingSign(
            SignException('err',
                'Radio returned ERR during sign (error code $errorCode)'),
            startError: SignException('unsupported',
                'Radio rejected CMD_SIGN_START (error code $errorCode)'),
          )) {
            break;
          }
          // Time sync: error code 6 (ERR_CODE_ILLEGAL_ARG) means "no sync needed" — treat as success
          if (_setTimeCompleter != null) {
            if (errorCode == 6) {
              debugLog(
                  '[CONN] Time sync not needed (error code 6) - treating as success');
            } else {
              debugWarn(
                  '[CONN] Time sync error (code $errorCode) - continuing anyway');
            }
            _setTimeCompleter?.complete();
            _setTimeCompleter = null;
            break;
          }
          // Complete any pending completers with error
          final errException = Exception('Command error (code $errorCode)');
          _statsCompleter?.completeError(errException);
          _statsCompleter = null;
          _channelInfoCompleter?.completeError(errException);
          _channelInfoCompleter = null;
          _deviceQueryCompleter?.completeError(errException);
          _deviceQueryCompleter = null;
          _exportContactCompleter?.completeError(errException);
          _exportContactCompleter = null;
          _getTimeCompleter?.completeError(errException);
          _getTimeCompleter = null;
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
        case PushCodes.traceData:
          _onTraceDataPush(reader);
          break;
        case ResponseCodes.stats:
          _onStatsResponse(reader);
          break;
        case ResponseCodes.batteryVoltage:
          _onBatteryVoltageResponse(reader);
          break;
        case ResponseCodes.currTime:
          if (_getTimeCompleter != null && reader.remainingBytesCount >= 4) {
            _getTimeCompleter?.complete(reader.readUInt32LE());
            _getTimeCompleter = null;
          }
          break;
        case ResponseCodes.exportContact:
          _onExportContactResponse(reader);
          break;
        case ResponseCodes.signStart:
          {
            final completer = _signStartCompleter;
            _signStartCompleter = null;
            if (completer == null || completer.isCompleted) {
              debugLog('[CONN] Ignoring unsolicited SIGN_START response');
              break;
            }
            // [reserved:1][maxSignDataLen:u32 LE]
            if (reader.remainingBytesCount < 5) {
              completer.completeError(const SignException('malformed_response',
                  'SIGN_START response is shorter than 5 bytes'));
              break;
            }
            reader.readByte(); // reserved
            completer.complete(reader.readUInt32LE());
            break;
          }
        case ResponseCodes.signature:
          {
            final completer = _signatureCompleter;
            _signatureCompleter = null;
            if (completer == null || completer.isCompleted) {
              debugLog('[CONN] Ignoring unsolicited SIGNATURE response');
              break;
            }
            // Guard BEFORE readBytes(64): a short frame must fast-fail here,
            // otherwise it becomes a RangeError swallowed by the outer catch
            // and the caller waits out the full 5s timeout for nothing.
            if (reader.remainingBytesCount < 64) {
              completer.completeError(SignException(
                  'malformed_response',
                  'SIGNATURE response carries ${reader.remainingBytesCount} '
                      'bytes, expected 64'));
              break;
            }
            completer.complete(reader.readBytes(64));
            break;
          }
        default:
          // Log unhandled response codes (like JS implementation)
          debugLog(
              '[CONN] Unhandled frame: code=$responseCode (0x${responseCode.toRadixString(16).padLeft(2, '0')})');
          break;
      }
    } catch (e, stack) {
      debugError('[CONN] Error processing frame (${frame.length} bytes): $e');
      debugError('[CONN] Frame hex: $frameDump');
      debugError('[CONN] Stack trace: $stack');
    }
  }

  /// Helper to convert bytes to hex string for debugging
  String _hexDump(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  }

  /// Complete every pending sign completer with an error. The SIGN_START
  /// completer gets [startError] when supplied, so an ERR at that stage reads
  /// as "this firmware has no CMD_SIGN" rather than a generic failure.
  ///
  /// Returns true when a sign was actually pending, so the caller can treat the
  /// frame as consumed.
  bool _failPendingSign(SignException error, {SignException? startError}) {
    final start = _signStartCompleter;
    final chunk = _signChunkOkCompleter;
    final signature = _signatureCompleter;
    if (start == null && chunk == null && signature == null) return false;

    _signStartCompleter = null;
    _signChunkOkCompleter = null;
    _signatureCompleter = null;

    if (start != null && !start.isCompleted) {
      start.completeError(startError ?? error);
    }
    if (chunk != null && !chunk.isCompleted) chunk.completeError(error);
    if (signature != null && !signature.isCompleted) {
      signature.completeError(error);
    }
    return true;
  }

  /// Tear down an in-flight sign on disconnect/dispose.
  ///
  /// Releasing the gate here is what keeps disconnect fast: the wardriving
  /// channel deletion is a normal (gated) write, so leaving the gate closed
  /// would park it behind the sign's 5s timeout while the link is dying.
  void _abortPendingSign() {
    final wasPending = _failPendingSign(
        const SignException('aborted', 'Connection closed during sign'));
    final gate = _signGate;
    _signGate = null;
    _signInProgress = false;
    if (gate != null && !gate.isCompleted) gate.complete();
    if (wasPending) debugLog('[CONN] Aborted in-flight sign');
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

      // Read manufacturer model as CString(40) — fixed-length null-terminated
      final manufacturerModel = reader.readCString(40);

      // Parse additional fields from v9+ firmware
      int? pathHashMode;
      String? firmwareVersionString;
      if (reader.remainingBytesCount > 0) {
        // FIRMWARE_VERSION: 20-byte null-terminated C-string
        if (reader.remainingBytesCount >= 20) {
          firmwareVersionString = reader.readCString(20);
          debugLog('[CONN] Firmware version string: $firmwareVersionString');
        }

        // client_repeat: 1 byte (v9+, skip)
        if (reader.remainingBytesCount >= 1) {
          reader.readByte(); // client_repeat
        }

        // path_hash_mode: 1 byte (v10+)
        if (reader.remainingBytesCount >= 1) {
          pathHashMode = reader.readByte();
          debugLog(
              '[CONN] Device path hash mode: $pathHashMode (${pathHashMode + 1}-byte hops)');
        }
      }

      debugLog('[CONN] Build date: $buildDate');
      debugLog('[CONN] Manufacturer model: $manufacturerModel');

      final response = DeviceQueryResponse(
        protocolVersion: firmwareVer,
        manufacturer: manufacturerModel,
        firmwareBuildDate: buildDate,
        firmwareVersionString: firmwareVersionString,
        pathHashMode: pathHashMode,
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

      // Additional fields added in newer firmware versions, between publicKey and name
      // (MeshCore companion protocol RESP_CODE_SELF_INFO). Older firmware omits this block.
      // Encoding note: the wiki documents radioFreq as uint32 Hz, but real hardware reports
      // it in kHz (a 910.525 MHz radio sends 910525); radioBw is uint32 Hz; SF/CR are bytes.
      int? radioFreqKHz;
      int? radioBwHz;
      int? radioSf;
      int? radioCr;
      if (reader.remainingBytesCount >= 22) {
        reader.readInt32LE(); // advLat
        reader.readInt32LE(); // advLon
        reader.readBytes(3); // reserved
        reader.readByte(); // manualAddContacts
        radioFreqKHz =
            reader.readUInt32LE(); // radioFreq (kHz on real hardware)
        radioBwHz = reader.readUInt32LE(); // radioBw (Hz)
        radioSf = reader.readByte(); // radioSf
        radioCr = reader.readByte(); // radioCr
      }

      // Read name from remaining bytes
      final name = reader.hasMoreBytes ? reader.readString() : '';

      final selfInfo = SelfInfo(
        type: type,
        txPower: txPower,
        maxTxPower: maxTxPower,
        publicKey: publicKey,
        name: name,
        radioFreqKHz: radioFreqKHz,
        radioBwHz: radioBwHz,
        radioSf: radioSf,
        radioCr: radioCr,
      );

      _selfInfo = selfInfo;
      debugLog(
          '[CONN] SelfInfo received: name="${selfInfo.name}", publicKey=${selfInfo.publicKeyHex.substring(0, 16)}..., radio=${selfInfo.radioConfigApi ?? "n/a"}');
      // Raw radio values straight off the device — surfaces the actual encoding in the
      // downloadable debug log (diagnoses any future unit questions).
      debugLog(
          '[CONN] Radio raw: freqKHz=$radioFreqKHz bwHz=$radioBwHz sf=$radioSf cr=$radioCr → ${selfInfo.radioConfigApi ?? "n/a"}');

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

  void _onTraceDataPush(BufferReader reader) {
    // 0x89 TraceData has NO snr/rssi prefix (unlike 0x88 LogRxData).
    // The entire remaining payload is the trace response:
    // [reserved][path_len][flags][tag:4][auth:4][path_hashes][path_snrs]
    final raw = reader.readRemainingBytes();

    debugLog('[CONN] Received trace data: ${raw.length} bytes');

    _traceDataController.add(raw);
  }

  void _onStatsResponse(BufferReader reader) {
    // Stats response format (from web client):
    // <stats_type:1> <noise:int16> <last_rssi:int8> <last_snr:int8> <tx_air_secs:uint32> <rx_air_secs:uint32>
    // Valid stats payload is 13 bytes. Some firmware versions send peer info
    // frames on the same response code (0x18) at 82+ bytes — reject those.
    if (reader.remainingBytesCount > 30) {
      _statsCompleter?.complete(0);
      _statsCompleter = null;
      return;
    }
    try {
      final statsType = reader.readByte();
      if (statsType == StatsTypes.radio) {
        final noiseFloor = reader.readInt16LE();
        // Skip remaining fields (lastRssi, lastSnr, txAirSecs, rxAirSecs)
        if (noiseFloor == 0) {
          // MeshCore 1.14.x AGC reset zeroes out noise floor briefly; discard
          debugLog('[CONN] Noise floor reading is 0dBm (AGC reset), ignoring');
          _statsCompleter?.complete(0);
        } else {
          _lastNoiseFloor = noiseFloor;
          _noiseFloorController.add(noiseFloor); // Emit to stream
          debugLog('[CONN] Noise floor updated: ${noiseFloor}dBm');
          _statsCompleter?.complete(noiseFloor);
        }
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
        debugLog(
            '[CONN] Battery response has ${extraBytes.length} extra bytes (ignoring)');
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

  void _onExportContactResponse(BufferReader reader) {
    try {
      final advertPacketBytes = reader.readRemainingBytes();
      final hexString = advertPacketBytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join('');
      final contactUri = 'meshcore://$hexString';

      debugLog(
          '[CONN] Received export contact: ${contactUri.substring(0, 50)}...');

      _exportContactCompleter?.complete(contactUri);
      _exportContactCompleter = null;
    } catch (e) {
      debugError('[CONN] Error parsing export contact response: $e');
      _exportContactCompleter?.completeError(e);
      _exportContactCompleter = null;
    }
  }

  /// The ONE outbound funnel. Every frame this class sends goes through here.
  ///
  /// While a sign is in flight, non-sign frames wait for it to finish. That
  /// matters because CMD_SIGN_DATA is acked with a bare OK (0x00) and so are
  /// setFloodScope, setChannel, setPathHashMode, setAdvertName and setTxPower —
  /// letting one of those onto the wire mid-sign means its OK is consumed as
  /// the chunk ack and the handshake desynchronises. Sign's own frames pass
  /// [isSignFrame] and bypass the gate.
  Future<void> _write(Uint8List bytes, {bool isSignFrame = false}) async {
    if (!isSignFrame) {
      final gate = _signGate;
      if (gate != null && !gate.isCompleted) {
        final code = bytes.isNotEmpty ? bytes[0] : -1;
        debugLog('[CONN] Queuing command $code behind an in-progress sign');
        // The gate future NEVER completes with an error, so a queued command
        // is delayed, never failed.
        await gate.future;
      }
    }
    await _transport.write(bytes);
  }

  /// Write frame to device
  Future<void> _sendToRadio(BufferWriter data) async {
    await _write(data.toBytes());
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
  Future<SelfInfo> getSelfInfo(
      {Duration timeout = const Duration(seconds: 5)}) async {
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

    // Send APP_START so device enters companion mode.
    // Without this, some devices won't respond to the device query.
    await sendCommandAppStart();

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Device query timed out'),
    );
  }

  /// Set device time and await OK/ERROR response from device
  Future<void> setDeviceTime(int epochSecs) async {
    _setTimeCompleter = Completer<void>();
    final future = _setTimeCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.setDeviceTime);
    data.writeUInt32LE(epochSecs);
    await _sendToRadio(data);

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _setTimeCompleter = null;
        debugWarn('[CONN] Time sync timed out - continuing anyway');
      },
    );
  }

  /// Query the device's current RTC clock (epoch seconds)
  Future<int> getDeviceTime() async {
    _getTimeCompleter = Completer<int>();
    final future = _getTimeCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.getDeviceTime);
    await _sendToRadio(data);

    return future.timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        _getTimeCompleter = null;
        throw TimeoutException('getDeviceTime timed out');
      },
    );
  }

  /// Set TX power
  Future<void> setTxPower(int txPower) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setTxPower);
    data.writeByte(txPower);
    await _sendToRadio(data);
  }

  /// Set the companion advertised name
  Future<void> setAdvertName(String name) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setAdvertName);
    data.writeString(name);
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
    data.writeByte(CommandCodes.getChannel); // 31 (0x1F)
    data.writeByte(channelIdx);
    final bytes = data.toBytes();
    debugLog(
        '[CONN] getChannel bytes: ${bytes.map((b) => '0x${b.toRadixString(16).padLeft(2, '0')}').join(' ')}');
    await _write(bytes);

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

  /// Set flood scope for regional packet filtering
  /// TransportKey is 16-byte SHA-256 derived key from scope name
  Future<void> setFloodScope(Uint8List transportKey) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setFloodScope);
    data.writeByte(0); // reserved byte
    data.writeBytes(transportKey); // 16-byte key
    await _sendToRadio(data);
  }

  /// Clear flood scope (return to unscoped global flood)
  Future<void> clearFloodScope() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setFloodScope);
    data.writeByte(0); // reserved byte — no key means clear
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
      return channels
          .firstWhere((channel) => _areBuffersEqual(channel.secret, secret));
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
  Future<void> sendChannelTextMessage(
      int txtType, int channelIdx, int senderTimestamp, String text) async {
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

  /// Send a pre-composed TX body to the #wardriving channel.
  /// The caller composes the body (privacy wire tag "MM:..." by default, or the
  /// legacy "@[MapperBot] LAT, LON" when the user opts into broadcasting coords)
  /// so the exact same string is used for both TxTracker echo matching and the
  /// actual transmission.
  /// Power is not included in the mesh message — it is sent per-ping in the API payload.
  Future<void> sendPing(String message) async {
    final channel = _wardrivingChannel;
    if (channel == null) {
      throw Exception('Wardriving channel not initialized');
    }

    debugLog('[CONN] Sending ping: $message');
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await sendChannelTextMessage(
        TxtTypes.plain, channel.channelIndex, timestamp, message);
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
    data.writeByte(CommandCodes.sendControlData); // 0x37
    data.writeByte(DiscoveryConstants.discoverReqFlag); // 0x80 = DISCOVER_REQ
    data.writeByte(
        DiscoveryConstants.typeFilterRepeaterRoom); // 0x0C = REPEATER | ROOM
    data.writeBytes(tag); // 4-byte random tag
    data.writeUInt32LE(0); // timestamp = 0 (discover all)
    await _sendToRadio(data);

    return tag;
  }

  /// Send trace path to a specific repeater (targeted ping / zero-hop trace)
  /// Returns the 4-byte tag used for matching the response
  /// [hopBytes] controls trace ID size: 1, 2, or 4 bytes (bitshift encoding)
  Future<Uint8List> sendTracePath(Uint8List repeaterIdBytes,
      {int hopBytes = 1}) async {
    final random = Random.secure();
    final tag = Uint8List.fromList([
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
      random.nextInt(256),
    ]);

    // Trace uses bitshift encoding: actual_bytes = 1 << path_sz
    // 1 → path_sz=0, 2 → path_sz=1, 4 → path_sz=2
    final int pathSz;
    switch (hopBytes) {
      case 4:
        pathSz = 2;
        break;
      case 2:
        pathSz = 1;
        break;
      default:
        pathSz = 0;
        break;
    }
    final int flags = pathSz & 0x03;

    debugLog(
        '[CONN] Sending trace to ${repeaterIdBytes.map((b) => b.toRadixString(16).padLeft(2, "0")).join("")} (traceBytes=$hopBytes, path_sz=$pathSz)');

    final data = BufferWriter();
    data.writeByte(CommandCodes.sendTracePath); // 0x24
    data.writeBytes(tag); // 4-byte tag
    data.writeUInt32LE(0); // auth_code = 0
    data.writeByte(flags); // flags with path_sz in bits 0-1
    data.writeBytes(repeaterIdBytes); // target repeater ID
    await _sendToRadio(data);
    return tag;
  }

  /// Get battery voltage
  Future<void> getBatteryVoltage() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.getBatteryVoltage);
    await _sendToRadio(data);
  }

  /// Export signed contact URI for API authentication
  /// Returns meshcore:// URI containing signed ADVERT packet
  Future<String> exportContact(
      {Duration timeout = const Duration(seconds: 5)}) async {
    _exportContactCompleter = Completer<String>();
    final future = _exportContactCompleter!.future;

    final data = BufferWriter();
    data.writeByte(CommandCodes.exportContact); // 0x11
    await _sendToRadio(data);

    return future.timeout(
      timeout,
      onTimeout: () => throw TimeoutException('Export contact timed out'),
    );
  }

  /// Ask the radio to Ed25519-sign [data] with its device private key.
  ///
  /// Framing (byte-identical to the portal's meshcore.js, which minted every
  /// existing `portal_pubkeys` row):
  ///   CMD_SIGN_START  (0x21)                    -> RESP_SIGN_START (19)
  ///   CMD_SIGN_DATA   (0x22) + <=128 data bytes -> OK (0x00), one per chunk
  ///   CMD_SIGN_FINISH (0x23)                    -> RESP_SIGNATURE (20) [64]
  ///
  /// Sign the RAW bytes, never their hex text. Throws [SignException] for
  /// protocol failures, [TimeoutException] when the radio goes quiet, and
  /// [StateError] when the connection is disposed or a sign is already running.
  Future<Uint8List> sign(Uint8List data,
      {Duration timeout = const Duration(seconds: 5)}) async {
    if (_disposed) {
      throw StateError('Cannot sign on a disposed connection');
    }
    if (_signInProgress) {
      throw StateError('A sign is already in progress');
    }

    _signInProgress = true;
    final gate = Completer<void>();
    _signGate = gate;
    debugLog('[CONN] sign: starting (${data.length} bytes)');

    try {
      // 1) SIGN_START -> maxSignDataLen
      final startCompleter = Completer<int>();
      _signStartCompleter = startCompleter;
      final startFrame = BufferWriter()..writeByte(CommandCodes.signStart);
      await _write(startFrame.toBytes(), isSignFrame: true);
      final maxSignDataLen = await startCompleter.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException('sign: SIGN_START timed out'),
      );
      debugLog('[CONN] sign: maxSignDataLen=$maxSignDataLen');

      if (data.length > maxSignDataLen) {
        throw SignException('data_too_long',
            'Payload is ${data.length} bytes, radio accepts $maxSignDataLen');
      }

      // 2) SIGN_DATA chunks, one OK each
      final chunkSize = min(128, maxSignDataLen);
      for (var offset = 0; offset < data.length; offset += chunkSize) {
        final end = min(offset + chunkSize, data.length);
        final okCompleter = Completer<void>();
        _signChunkOkCompleter = okCompleter;
        final chunkFrame = BufferWriter()
          ..writeByte(CommandCodes.signData)
          ..writeBytes(data.sublist(offset, end));
        await _write(chunkFrame.toBytes(), isSignFrame: true);
        await okCompleter.future.timeout(
          timeout,
          onTimeout: () => throw TimeoutException('sign: chunk ack timed out'),
        );
        debugLog('[CONN] sign: chunk acked (${end - offset} bytes)');
      }

      // 3) SIGN_FINISH -> signature
      final sigCompleter = Completer<Uint8List>();
      _signatureCompleter = sigCompleter;
      final finishFrame = BufferWriter()..writeByte(CommandCodes.signFinish);
      await _write(finishFrame.toBytes(), isSignFrame: true);
      final signature = await sigCompleter.future.timeout(
        timeout,
        onTimeout: () => throw TimeoutException('sign: signature timed out'),
      );

      if (signature.length != 64) {
        throw SignException('bad_signature_length',
            'Radio returned ${signature.length} bytes, expected 64');
      }
      debugLog('[CONN] sign: signature received');
      return signature;
    } finally {
      // Clear on EVERY path (success, throw, timeout) or the next sign
      // inherits a stale completer and hangs.
      _signStartCompleter = null;
      _signChunkOkCompleter = null;
      _signatureCompleter = null;
      _signInProgress = false;
      if (identical(_signGate, gate)) _signGate = null;
      if (!gate.isCompleted) gate.complete();
    }
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
    _isFetchingNoiseFloor = false;
    _noiseFloorFailCount = 0;

    // Get initial reading immediately
    _fetchNoiseFloor();

    _noiseFloorTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
      await _fetchNoiseFloor();
    });

    debugLog('[CONN] Started noise floor polling (5s interval)');
  }

  Future<void> _fetchNoiseFloor() async {
    if (_isFetchingNoiseFloor) return; // Skip if previous fetch still in flight
    _isFetchingNoiseFloor = true;
    try {
      debugLog('[CONN] Fetching noise floor...');
      await getNoiseFloor();
      _noiseFloorFailCount = 0; // Reset on success
    } catch (e) {
      _noiseFloorFailCount++;
      debugLog('[CONN] Noise floor fetch failed ($_noiseFloorFailCount/3): $e');
      if (_noiseFloorFailCount >= 3) {
        debugLog(
            '[CONN] Noise floor polling stopped after 3 consecutive failures');
        _stopNoiseFloorPolling();
      }
    } finally {
      _isFetchingNoiseFloor = false;
    }
  }

  /// Stop noise floor polling
  void _stopNoiseFloorPolling() {
    _noiseFloorTimer?.cancel();
    _noiseFloorTimer = null;
    _isFetchingNoiseFloor = false;
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

  /// Set path hash mode on the radio
  /// mode: 0=1-byte, 1=2-byte, 2=3-byte (persisted in radio prefs)
  Future<void> setPathHashMode(int mode) async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.setPathHashMode); // 61 (0x3D)
    data.writeByte(0); // reserved
    data.writeByte(mode); // 0=1-byte, 1=2-byte, 2=3-byte
    await _sendToRadio(data);
    debugLog('[CONN] Sent setPathHashMode: mode=$mode (${mode + 1}-byte hops)');
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
    _disposed = true;
    _stopNoiseFloorPolling();
    _stopBatteryPolling();
    _abortPendingSign();
    _setTimeCompleter = null;
    _dataSubscription?.cancel();
    _stepController.close();
    _channelMessageController.close();
    _rawDataController.close();
    _logRxDataController.close();
    _controlDataController.close();
    _traceDataController.close();
    _noiseFloorController.close();
    _batteryController.close();
  }
}
