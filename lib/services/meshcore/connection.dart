import 'dart:async';
import 'dart:typed_data';

import '../../models/connection_state.dart';
import '../../models/device_model.dart';
import '../bluetooth/bluetooth_service.dart';
import 'buffer_utils.dart';
import 'packet_parser.dart';
import 'protocol_constants.dart';

/// Response from device query command
class DeviceQueryResponse {
  final int protocolVersion;
  final String manufacturer;
  final Uint8List publicKey;

  const DeviceQueryResponse({
    required this.protocolVersion,
    required this.manufacturer,
    required this.publicKey,
  });
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

  ConnectionStep _currentStep = ConnectionStep.disconnected;
  DeviceQueryResponse? _deviceInfo;
  DeviceModel? _deviceModel;
  StreamSubscription? _dataSubscription;

  // Completers for command responses
  Completer<DeviceQueryResponse>? _deviceQueryCompleter;
  Completer<void>? _sentCompleter;
  Completer<ChannelInfo>? _channelInfoCompleter;

  MeshCoreConnection({required BluetoothService bluetooth}) : _bluetooth = bluetooth {
    _dataSubscription = _bluetooth.dataStream.listen(_onFrameReceived);
  }

  /// Stream of connection step changes
  Stream<ConnectionStep> get stepStream => _stepController.stream;

  /// Stream of channel messages (for RX pings)
  Stream<ChannelMessage> get channelMessageStream => _channelMessageController.stream;

  /// Stream of raw data pushes
  Stream<Map<String, dynamic>> get rawDataStream => _rawDataController.stream;

  /// Current connection step
  ConnectionStep get currentStep => _currentStep;

  /// Device info from query (null if not connected)
  DeviceQueryResponse? get deviceInfo => _deviceInfo;

  /// Matched device model (null if not connected or unknown)
  DeviceModel? get deviceModel => _deviceModel;

  void _updateStep(ConnectionStep step) {
    _currentStep = step;
    _stepController.add(step);
  }

  /// Execute the full connection workflow
  Future<void> connect(String deviceId, List<DeviceModel> deviceModels) async {
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

      // Step 4: Power Configuration (auto-select based on device model)
      _updateStep(ConnectionStep.powerConfiguration);
      _deviceModel = _matchDeviceModel(_deviceInfo!.manufacturer, deviceModels);
      if (_deviceModel != null) {
        await setTxPower(_deviceModel!.txPower);
      }

      // Step 5: Time Sync
      _updateStep(ConnectionStep.timeSync);
      await setDeviceTime(DateTime.now().millisecondsSinceEpoch ~/ 1000);

      // Step 6: Slot Acquisition (handled by API service)
      _updateStep(ConnectionStep.slotAcquisition);
      // API slot acquisition is handled externally

      // Step 7: Channel Setup
      _updateStep(ConnectionStep.channelSetup);
      // Channel is pre-configured on device

      // Step 8: GPS Init (handled externally)
      _updateStep(ConnectionStep.gpsInit);
      // GPS init is handled by GPS service

      // Step 9: Connected
      _updateStep(ConnectionStep.connected);
    } catch (e) {
      _updateStep(ConnectionStep.error);
      rethrow;
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

  /// Disconnect from device
  Future<void> disconnect() async {
    await _bluetooth.disconnect();
    _deviceInfo = null;
    _deviceModel = null;
    _updateStep(ConnectionStep.disconnected);
  }

  /// Handle incoming frame from device
  void _onFrameReceived(Uint8List frame) {
    if (frame.isEmpty) return;

    final reader = BufferReader(frame);
    final responseCode = reader.readByte();

    switch (responseCode) {
      case ResponseCodes.deviceInfo:
        _onDeviceInfoResponse(reader);
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
      default:
        // Ignore unhandled response codes
        break;
    }
  }

  void _onDeviceInfoResponse(BufferReader reader) {
    final protocolVersion = reader.readByte();
    final manufacturer = reader.readCString(64);
    final publicKey = reader.readBytes(32);

    final response = DeviceQueryResponse(
      protocolVersion: protocolVersion,
      manufacturer: manufacturer,
      publicKey: publicKey,
    );

    _deviceQueryCompleter?.complete(response);
    _deviceQueryCompleter = null;
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

    _rawDataController.add({
      'snr': snr,
      'rssi': rssi,
      'raw': raw,
    });
  }

  /// Write frame to device
  Future<void> _sendToRadio(BufferWriter data) async {
    await _bluetooth.write(data.toBytes());
  }

  // ============================================
  // Command Methods (ported from connection.js)
  // ============================================

  /// Query device info
  Future<DeviceQueryResponse> deviceQuery(int appTargetVer) async {
    _deviceQueryCompleter = Completer<DeviceQueryResponse>();

    final data = BufferWriter();
    data.writeByte(CommandCodes.deviceQuery);
    data.writeByte(appTargetVer);
    await _sendToRadio(data);

    return _deviceQueryCompleter!.future.timeout(
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
    _channelInfoCompleter = Completer<ChannelInfo>();

    final data = BufferWriter();
    data.writeByte(CommandCodes.getChannel);
    data.writeByte(channelIdx);
    await _sendToRadio(data);

    return _channelInfoCompleter!.future.timeout(
      const Duration(seconds: 5),
      onTimeout: () => throw TimeoutException('Get channel timed out'),
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

  /// Send channel text message (for TX pings)
  /// Reference: sendCommandSendChannelTxtMsg in connection.js
  Future<void> sendChannelTextMessage(int txtType, int channelIdx, int senderTimestamp, String text) async {
    _sentCompleter = Completer<void>();

    final data = BufferWriter();
    data.writeByte(CommandCodes.sendChannelTxtMsg);
    data.writeByte(txtType);
    data.writeByte(channelIdx);
    data.writeUInt32LE(senderTimestamp);
    data.writeString(text);
    await _sendToRadio(data);

    // Wait for sent confirmation (with timeout)
    await _sentCompleter!.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () {
        // Ignore timeout - message may still be sent
      },
    );
  }

  /// Send ping to #wardriving channel
  /// Format: @[MapperBot]<LAT LON>[power]
  Future<void> sendPing(double lat, double lon, int power) async {
    final message = '@[MapperBot]<$lat $lon>[$power]';
    final timestamp = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    await sendChannelTextMessage(TxtTypes.plain, 0, timestamp, message);
  }

  /// Get battery voltage
  Future<void> getBatteryVoltage() async {
    final data = BufferWriter();
    data.writeByte(CommandCodes.getBatteryVoltage);
    await _sendToRadio(data);
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
    _dataSubscription?.cancel();
    _stepController.close();
    _channelMessageController.close();
    _rawDataController.close();
  }
}
