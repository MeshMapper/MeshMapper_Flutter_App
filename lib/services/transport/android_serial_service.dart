import 'dart:async';

import 'package:flutter/services.dart';

import '../../utils/debug_logger_io.dart';
import '../bluetooth/bluetooth_service.dart';
import 'stream_transport_base.dart';

/// USB Serial transport for Android via USB OTG.
///
/// Uses a native Kotlin implementation (MeshMapperUsbService) that directly
/// accesses Android's USB API with proper CDC control transfers.
class AndroidSerialService extends StreamTransportBase {
  final String deviceName;
  final String productName;

  static const _methodChannel = MethodChannel('net.meshmapper.app/usb_serial');
  static const _eventChannel =
      EventChannel('net.meshmapper.app/usb_serial/data');

  StreamSubscription? _dataSubscription;

  AndroidSerialService({
    required this.deviceName,
    required this.productName,
  });

  @override
  Future<void> openConnection() async {
    debugLog('[CONN] USB Serial connecting to $productName');
    setConnecting();

    try {
      _dataSubscription = _eventChannel.receiveBroadcastStream().listen(
        (data) {
          if (data is Uint8List) {
            onRawBytesReceived(data);
          } else if (data is List) {
            onRawBytesReceived(Uint8List.fromList(data.cast<int>()));
          }
        },
        onError: (error) {
          debugError('[CONN] USB Serial stream error: $error');
          setDisconnected();
        },
        onDone: () {
          debugLog('[CONN] USB Serial stream closed');
          setDisconnected();
        },
      );

      final connectResult = await _methodChannel.invokeMethod<Map>('connect', {
        'deviceName': deviceName,
        'baudRate': 115200,
      });
      if (connectResult != null) {
        debugLog(
            '[CONN] USB device info: controlFound=${connectResult['controlFound']}, '
            'interfaces=${connectResult['interfaceCount']}, '
            'dataClass=0x${(connectResult['dataClass'] as int?)?.toRadixString(16) ?? '?'}, '
            'inPacket=${connectResult['inMaxPacket']}, outPacket=${connectResult['outMaxPacket']}');
      }

      setConnected(DiscoveredDevice(
        id: deviceName,
        name: productName,
      ));

      debugLog('[CONN] USB Serial connected: $productName');
    } catch (e) {
      _dataSubscription?.cancel();
      _dataSubscription = null;
      debugError('[CONN] USB Serial connection failed: $e');
      setError();
      rethrow;
    }
  }

  @override
  Future<void> writeRawBytes(Uint8List data) async {
    await _methodChannel.invokeMethod('write', {'data': data});
  }

  @override
  Future<void> closeConnection() async {
    try {
      final diag = await _methodChannel.invokeMethod<Map>('readDiagnostics');
      if (diag != null) {
        debugLog('[CONN] USB read loop: '
            'reads=${diag['readAttempts']}, '
            'bytesRx=${diag['bytesReceived']}, '
            'events=${diag['eventsPosted']}, '
            'sinkNull=${diag['sinkNullCount']}, '
            'reading=${diag['isReading']}, '
            'threadAlive=${diag['threadAlive']}, '
            'sinkSet=${diag['sinkSet']}');
      }
    } catch (e) {
      debugWarn('[CONN] Read diagnostics unavailable: $e');
    }
    _dataSubscription?.cancel();
    _dataSubscription = null;
    try {
      await _methodChannel.invokeMethod('disconnect');
    } catch (e) {
      debugError('[CONN] USB Serial disconnect error: $e');
    }
    debugLog('[CONN] USB Serial connection closed');
  }

  @override
  void dispose() {
    _dataSubscription?.cancel();
    _dataSubscription = null;
    try {
      _methodChannel.invokeMethod('disconnect');
    } catch (_) {}
    super.dispose();
  }

  /// List available USB serial devices via native Android USB API.
  static Future<List<Map<String, dynamic>>> getAvailablePorts() async {
    final result = await _methodChannel.invokeMethod<List>('listDevices');
    if (result == null) return [];
    return result.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
}
