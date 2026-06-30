import 'dart:async';
import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

import '../../utils/debug_logger_io.dart';
import '../bluetooth/bluetooth_service.dart';
import 'stream_transport_base.dart';

// Web Serial API JS interop bindings

@JS('navigator.serial')
external JSObject? get _jsNavigatorSerial;

extension type SerialApi._(JSObject _) implements JSObject {
  external JSPromise<JSObject> requestPort([JSObject? options]);
}

extension type SerialPort._(JSObject _) implements JSObject {
  external JSPromise<JSAny?> open(JSObject options);
  external JSPromise<JSAny?> close();
  external web.ReadableStream get readable;
  external web.WritableStream get writable;
}

extension type SerialOptions._(JSObject _) implements JSObject {
  external factory SerialOptions({int baudRate});
}

/// USB Serial transport for web browsers via the Web Serial API.
///
/// Uses `navigator.serial` (Chrome/Edge only). The browser shows a native
/// port picker dialog when [openConnection] is called.
class WebSerialService extends StreamTransportBase {
  SerialPort? _port;
  web.ReadableStreamDefaultReader? _reader;
  bool _reading = false;

  @override
  Future<void> openConnection() async {
    debugLog('[CONN] Web Serial: requesting port');
    setConnecting();

    try {
      final serial = _jsNavigatorSerial;
      if (serial == null) {
        throw UnsupportedError('Web Serial API not available in this browser');
      }

      final serialApi = SerialApi._(serial);
      final portObj = await serialApi.requestPort().toDart;
      _port = SerialPort._(portObj);
      await _port!.open(SerialOptions(baudRate: 115200)).toDart;

      setConnected(const DiscoveredDevice(
        id: 'webserial',
        name: 'USB Serial (Web)',
      ));

      _startReadLoop();
      debugLog('[CONN] Web Serial connected');
    } catch (e) {
      debugError('[CONN] Web Serial connection failed: $e');
      setError();
      rethrow;
    }
  }

  void _startReadLoop() async {
    _reader = _port!.readable.getReader() as web.ReadableStreamDefaultReader;
    _reading = true;

    try {
      while (_reading) {
        final result = await _reader!.read().toDart;
        if (result.done) break;

        final value = result.value;
        if (value != null) {
          final jsArray = value as JSUint8Array;
          final bytes = jsArray.toDart;
          onRawBytesReceived(bytes);
        }
      }
    } catch (e) {
      if (_reading) {
        debugError('[CONN] Web Serial read error: $e');
        setDisconnected();
      }
    }
  }

  @override
  Future<void> writeRawBytes(Uint8List data) async {
    final writer = _port!.writable.getWriter();
    try {
      final jsData = data.toJS;
      await writer.write(jsData).toDart;
    } finally {
      writer.releaseLock();
    }
  }

  @override
  Future<void> closeConnection() async {
    _reading = false;
    try {
      await _reader?.cancel().toDart;
    } catch (_) {}
    _reader = null;
    try {
      await _port?.close().toDart;
    } catch (_) {}
    _port = null;
    debugLog('[CONN] Web Serial connection closed');
  }

  @override
  void dispose() {
    _reading = false;
    _reader?.cancel();
    super.dispose();
  }

  /// Check if Web Serial API is available in this browser.
  static bool get isAvailable => _jsNavigatorSerial != null;
}
