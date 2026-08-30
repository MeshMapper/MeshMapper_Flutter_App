import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart' as fbp;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../models/connection_state.dart';
import '../../utils/debug_logger_io.dart';
import '../meshcore/protocol_constants.dart';
import 'ble_connect_retry_policy.dart';
import 'bluetooth_service.dart';

/// Mobile Bluetooth implementation using flutter_blue_plus
/// For Android and iOS platforms
class MobileBluetoothService implements BluetoothService {
  // Retry constants for transient connect failures (see ble_connect_retry_policy.dart)
  static const int _maxRetries = 3;
  static const Duration _retryDelay = Duration(milliseconds: 500);

  StreamController<ConnectionStatus>? _connectionController;
  StreamController<Uint8List>? _dataController;
  bool _isDisposed = false;

  ConnectionStatus _connectionStatus = ConnectionStatus.disconnected;

  MobileBluetoothService() {
    _initControllers();
  }

  void _initControllers() {
    _connectionController = StreamController<ConnectionStatus>.broadcast();
    _dataController = StreamController<Uint8List>.broadcast();
    _isDisposed = false;
  }

  void _ensureControllers() {
    if (_isDisposed ||
        _connectionController == null ||
        _connectionController!.isClosed) {
      _initControllers();
    }
  }

  DiscoveredDevice? _connectedDevice;
  fbp.BluetoothDevice? _bleDevice;
  fbp.BluetoothCharacteristic? _rxCharacteristic;
  fbp.BluetoothCharacteristic? _txCharacteristic;
  StreamSubscription? _connectionStateSubscription;
  StreamSubscription? _notificationSubscription;
  StreamSubscription? _scanSubscription;
  StreamController<DiscoveredDevice>? _scanController;

  // Store scanned device info for use in connect()
  // This preserves the device name from scan results
  final Map<String, DiscoveredDevice> _scannedDevices = {};

  @override
  Stream<ConnectionStatus> get connectionStream {
    _ensureControllers();
    return _connectionController!.stream;
  }

  @override
  Stream<Uint8List> get dataStream {
    _ensureControllers();
    return _dataController!.stream;
  }

  @override
  Stream<BluetoothAdapterState> get adapterStateStream {
    return fbp.FlutterBluePlus.adapterState.map((state) {
      switch (state) {
        case fbp.BluetoothAdapterState.on:
          return BluetoothAdapterState.on;
        case fbp.BluetoothAdapterState.off:
          return BluetoothAdapterState.off;
        case fbp.BluetoothAdapterState.turningOn:
          return BluetoothAdapterState.turningOn;
        case fbp.BluetoothAdapterState.turningOff:
          return BluetoothAdapterState.turningOff;
        case fbp.BluetoothAdapterState.unavailable:
          return BluetoothAdapterState.unavailable;
        default:
          return BluetoothAdapterState.unknown;
      }
    });
  }

  @override
  ConnectionStatus get connectionStatus => _connectionStatus;

  @override
  DiscoveredDevice? get connectedDevice => _connectedDevice;

  void _updateStatus(ConnectionStatus status) {
    _connectionStatus = status;
    _ensureControllers();
    if (!_connectionController!.isClosed) {
      _connectionController!.add(status);
    }
  }

  @override
  Future<bool> isAvailable() async {
    try {
      final supported = await fbp.FlutterBluePlus.isSupported;
      debugLog('[BLE] isAvailable: $supported');
      return supported;
    } catch (e) {
      debugLog('[BLE] isAvailable error: $e');
      return false;
    }
  }

  @override
  Future<bool> isEnabled() async {
    try {
      final state = await fbp.FlutterBluePlus.adapterState.first;
      final enabled = state == fbp.BluetoothAdapterState.on;
      debugLog('[BLE] isEnabled: $enabled (adapter state: $state)');
      return enabled;
    } catch (e) {
      debugLog('[BLE] isEnabled error: $e');
      return false;
    }
  }

  @override
  Future<bool> requestPermissions() async {
    if (Platform.isIOS) {
      // iOS: Core Bluetooth handles Bluetooth authorization automatically.
      // It will prompt the user when we first try to scan/connect.
      //
      // For location, we CHECK permissions but don't REQUEST them here.
      // Location permission requests are handled by the disclosure flow in MainScaffold.
      final locationPermission = await Geolocator.checkPermission();
      debugLog('[BLE] iOS location permission check: $locationPermission');

      if (locationPermission == LocationPermission.deniedForever) {
        debugLog(
            '[BLE] iOS location permission permanently denied - user must enable in Settings');
        throw BlePermissionDeniedException(
            'Location permission required for Bluetooth scanning. '
            'Please enable in Settings > Privacy & Security > Location Services > MeshMapper');
      }

      if (locationPermission == LocationPermission.denied) {
        debugLog(
            '[BLE] iOS location permission not yet granted (disclosure flow will handle)');
        return false;
      }

      debugLog(
          '[BLE] iOS permissions OK - Core Bluetooth will prompt for Bluetooth access when scanning');
      return true;
    } else {
      // Android: Use bluetoothScan and bluetoothConnect (Android 12+)
      // Note: Location permission is CHECKED but not REQUESTED here.
      // Location requests are handled by the disclosure flow in MainScaffold.
      final bluetoothScan = await Permission.bluetoothScan.request();
      final bluetoothConnect = await Permission.bluetoothConnect.request();
      final location = await Permission
          .locationWhenInUse.status; // CHECK only, don't request

      debugLog(
          '[BLE] Android permission check - scan: $bluetoothScan, connect: $bluetoothConnect, location: $location');

      // Check for permanently denied permissions
      if (bluetoothScan.isPermanentlyDenied ||
          bluetoothConnect.isPermanentlyDenied ||
          location.isPermanentlyDenied) {
        final denied = <String>[];
        if (bluetoothScan.isPermanentlyDenied) denied.add('Bluetooth Scan');
        if (bluetoothConnect.isPermanentlyDenied) {
          denied.add('Bluetooth Connect');
        }
        if (location.isPermanentlyDenied) denied.add('Location');
        debugLog(
            '[BLE] Android permissions permanently denied: ${denied.join(", ")}');
        throw BlePermissionDeniedException(
            '${denied.join(", ")} permission(s) denied. Please enable in Settings');
      }

      final granted = bluetoothScan.isGranted &&
          bluetoothConnect.isGranted &&
          location.isGranted;

      if (!granted) {
        debugLog('[BLE] Android permissions not fully granted');
      }

      return granted;
    }
  }

  @override
  Stream<DiscoveredDevice> scanForDevices({Duration? timeout}) async* {
    final controller = StreamController<DiscoveredDevice>();
    _scanController = controller;

    _updateStatus(ConnectionStatus.scanning);

    try {
      // Ensure any previous scan stream is closed before starting a new one
      await _scanSubscription?.cancel();
      _scanSubscription = null;

      // Start scanning with filter for MeshCore service UUID
      await fbp.FlutterBluePlus.startScan(
        withServices: [fbp.Guid(BleUuids.serviceUuid)],
        timeout: timeout ?? const Duration(seconds: 10),
      );

      // Listen for scan results
      _scanSubscription = fbp.FlutterBluePlus.scanResults.listen((results) {
        for (final result in results) {
          final hasName = result.device.platformName.isNotEmpty;
          final deviceName =
              hasName ? result.device.platformName : 'MeshCore Device';
          if (!hasName) {
            debugLog(
                '[BLE] WARNING: Device ${result.device.remoteId.str} has no platformName during scan, using fallback "MeshCore Device"');
          }
          final device = DiscoveredDevice(
            id: result.device.remoteId.str,
            name: deviceName,
            rssi: result.rssi,
          );
          // Store device info for use in connect() - preserves name from scan
          _scannedDevices[device.id] = device;
          if (!controller.isClosed) {
            controller.add(device);
          }
        }
      });

      // Complete stream when scan naturally stops (timeout or platform stop)
      unawaited(() async {
        await fbp.FlutterBluePlus.isScanning
            .where((isScanning) => !isScanning)
            .first;
        if (!controller.isClosed) {
          await controller.close();
        }
      }());

      yield* controller.stream;
    } finally {
      await _scanSubscription?.cancel();
      _scanSubscription = null;
      if (!controller.isClosed) {
        await controller.close();
      }
      if (identical(_scanController, controller)) {
        _scanController = null;
      }
    }
  }

  @override
  Future<void> stopScan() async {
    await fbp.FlutterBluePlus.stopScan();
    await _scanSubscription?.cancel();
    _scanSubscription = null;
    final scanController = _scanController;
    if (scanController != null && !scanController.isClosed) {
      await scanController.close();
    }
    _scanController = null;
    // NOTE: Do NOT fire 'disconnected' here. Stopping a scan is not a disconnection.
    // The status will be updated by connect() when a connection starts.
    // Firing 'disconnected' here causes a race condition where the queued event
    // arrives after a new MeshCoreConnection is created and disposes it incorrectly.
  }

  /// Bumped by every connect() call. A loop whose epoch is stale has been
  /// superseded by a newer connect and must stop retrying without touching
  /// the shared device state (_bleDevice, characteristics, subscriptions).
  int _connectEpoch = 0;

  @override
  Future<void> connect(String deviceId, {int? maxAttempts}) async {
    final epoch = ++_connectEpoch;
    final requested = maxAttempts ?? _maxRetries;
    final attemptLimit =
        requested < 1 ? 1 : (requested > _maxRetries ? _maxRetries : requested);
    int attempt = 0;

    while (attempt < attemptLimit) {
      attempt++;
      if (epoch != _connectEpoch) {
        throw Exception('Connection attempt superseded');
      }
      try {
        debugLog('[BLE] Connection attempt $attempt/$_maxRetries to $deviceId');
        _updateStatus(ConnectionStatus.connecting);

        // Cancel any existing subscriptions from a previous connection
        // This prevents old listeners from interfering with the new connection
        await _connectionStateSubscription?.cancel();
        _connectionStateSubscription = null;
        await _notificationSubscription?.cancel();
        _notificationSubscription = null;

        // Ensure controllers are initialized
        _ensureControllers();

        // Disconnect any previously connected device
        if (_bleDevice != null) {
          debugLog('[BLE] Disconnecting previous device');
          try {
            await _bleDevice!.disconnect();
          } catch (e) {
            debugLog('[BLE] Previous disconnect error (ignoring): $e');
          }
          _bleDevice = null;
        }

        // Get the device
        _bleDevice = fbp.BluetoothDevice.fromId(deviceId);
        debugLog('[BLE] Device reference created');

        // Connect to GATT server FIRST (before subscribing to state changes)
        debugLog('[BLE] Connecting to GATT...');
        await _bleDevice!.connect(
          timeout: const Duration(seconds: 15),
          mtu:
              null, // Disable automatic MTU negotiation during connect to avoid race condition errors on Android
        );
        debugLog('[BLE] GATT connected');

        // Request larger MTU AFTER connection is established
        // SelfInfo response needs ~60 bytes, ChannelInfo needs ~50 bytes
        // Request 512 to be safe (most devices support at least 185)
        // Note: iOS automatically negotiates MTU, but we still call this for consistency
        if (Platform.isAndroid) {
          try {
            final mtu = await _bleDevice!.requestMtu(512);
            debugLog('[BLE] MTU negotiated: $mtu bytes');
            // Small delay to ensure MTU takes effect on Android
            await Future.delayed(const Duration(milliseconds: 100));
          } catch (e) {
            // MTU negotiation failure is not fatal - continue with default MTU
            // Some older devices may not support MTU negotiation
            debugLog(
                '[BLE] MTU negotiation failed (continuing with default): $e');
          }
        } else {
          // iOS auto-negotiates MTU, just log the current value
          final mtu = await _bleDevice!.mtu.first;
          debugLog('[BLE] iOS MTU: $mtu bytes');
        }

        // NOW subscribe to connection state changes (after we're connected)
        // Use skip(1) to ignore the initial state emission from the stream.
        // Flutter Blue Plus emits the current state immediately when you subscribe,
        // but we only want to react to CHANGES, not the initial state.
        // This prevents false disconnection triggers during connection setup.
        _connectionStateSubscription =
            _bleDevice!.connectionState.skip(1).listen((state) {
          debugLog('[BLE] Connection state changed: $state');
          if (state == fbp.BluetoothConnectionState.disconnected) {
            _handleDisconnection();
          }
        });

        // Discover services
        debugLog('[BLE] Discovering services...');
        final services = await _bleDevice!.discoverServices();
        debugLog('[BLE] Found ${services.length} services');

        // Find our service
        final service = services.firstWhere(
          (s) => s.uuid.toString().toUpperCase() == BleUuids.serviceUuid,
          orElse: () => throw Exception('MeshCore service not found'),
        );
        debugLog('[BLE] Found MeshCore service');

        // Find characteristics
        for (final char in service.characteristics) {
          final uuid = char.uuid.toString().toUpperCase();
          if (uuid == BleUuids.characteristicRxUuid) {
            _rxCharacteristic = char;
            debugLog('[BLE] Found RX characteristic');
          } else if (uuid == BleUuids.characteristicTxUuid) {
            _txCharacteristic = char;
            debugLog('[BLE] Found TX characteristic');
          }
        }

        if (_rxCharacteristic == null || _txCharacteristic == null) {
          throw Exception('Required characteristics not found');
        }

        // Enable notifications on TX characteristic
        debugLog('[BLE] Enabling notifications...');
        await _txCharacteristic!.setNotifyValue(true);
        _notificationSubscription =
            _txCharacteristic!.lastValueStream.listen((value) {
          if (value.isNotEmpty &&
              _dataController != null &&
              !_dataController!.isClosed) {
            _dataController!.add(Uint8List.fromList(value));
          }
        });
        debugLog('[BLE] Notifications enabled');

        // Use device name from scan results if available, fallback to platformName
        final scannedDevice = _scannedDevices[deviceId];
        String deviceName;
        if (scannedDevice != null) {
          deviceName = scannedDevice.name;
        } else if (_bleDevice!.platformName.isNotEmpty) {
          deviceName = _bleDevice!.platformName;
        } else {
          deviceName = 'MeshCore Device';
          debugLog(
              '[BLE] WARNING: No device name available for $deviceId during connect - no scan cache, empty platformName. Using fallback "MeshCore Device"');
        }
        _connectedDevice = DiscoveredDevice(
          id: deviceId,
          name: deviceName,
        );
        if (deviceName == 'MeshCore Device') {
          debugLog(
              '[BLE] WARNING: Connected device name is "MeshCore Device" (from scan: ${scannedDevice != null}, scanName: ${scannedDevice?.name}, platformName: ${_bleDevice!.platformName})');
        } else {
          debugLog(
              '[BLE] Device name: $deviceName (from scan: ${scannedDevice != null}, platformName: ${_bleDevice!.platformName})');
        }

        if (epoch != _connectEpoch) {
          throw Exception('Connection attempt superseded');
        }
        debugLog('[BLE] Connection complete');
        _updateStatus(ConnectionStatus.connected);
        return; // Success - exit retry loop
      } catch (e, stackTrace) {
        if (epoch != _connectEpoch) {
          // A newer connect() owns the shared device state; retrying or
          // cleaning up here would stomp its fields mid-attempt.
          rethrow;
        }
        final action = classifyBleConnectFailure(
          errorString: e.toString(),
          isIos: Platform.isIOS,
          attempt: attempt,
          maxRetries: attemptLimit,
        );

        if (action == BleConnectFailureAction.abortForBondError) {
          debugLog('[BLE] Bond error (apple-code 14/15) on attempt $attempt');
          await removeBond(deviceId);
          // On iOS, removeBond() is a no-op (not supported by Core Bluetooth).
          // Don't burn internal retries against stale bond keys: they will all
          // fail the same way and each hangs for the full connect timeout.
          // Rethrow immediately so the auto-reconnect system can apply a longer
          // delay (giving iOS time to resolve) or inform the user.
          debugWarn(
              '[BLE] iOS bond error, skipping internal retries (stale keys cannot be cleared programmatically)');
          await _cleanupFailedAttempt();
          _updateStatus(ConnectionStatus.error);
          rethrow;
        }

        if (action == BleConnectFailureAction.retry) {
          debugLog(
              '[BLE] Attempt $attempt failed, retrying after delay... ($e)');
          await _cleanupFailedAttempt();
          await Future.delayed(_retryDelay);
          continue; // Retry
        }

        // Final attempt failed
        debugLog('[BLE] Connection error: $e');
        debugLog('[BLE] Stack trace: $stackTrace');
        _updateStatus(ConnectionStatus.error);
        rethrow;
      }
    }
  }

  /// Tear down a failed connect attempt without emitting a disconnected event.
  /// The state subscription is cancelled BEFORE the disconnect: attempts that
  /// fail after the GATT link is up (discovery, notifications) have the
  /// listener installed, and letting it fire _handleDisconnection would emit
  /// 'disconnected' and start full provider cleanup mid-retry.
  Future<void> _cleanupFailedAttempt() async {
    await _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    await _notificationSubscription?.cancel();
    _notificationSubscription = null;
    try {
      await _bleDevice?.disconnect();
    } catch (e) {
      debugWarn('[BLE] Failed to disconnect failed attempt: $e');
    }
    _bleDevice = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
  }

  void _handleDisconnection() {
    // Guard against double-disconnect: when disconnect() is called, the BLE
    // connectionState listener fires first, then the finally block also calls
    // this method. Only process the first call.
    if (_connectionStatus == ConnectionStatus.disconnected) {
      return;
    }

    _connectedDevice = null;
    _bleDevice = null;
    _rxCharacteristic = null;
    _txCharacteristic = null;
    _scannedDevices.clear(); // Clear scan cache on disconnect
    _notificationSubscription?.cancel();
    _notificationSubscription = null;
    _connectionStateSubscription?.cancel();
    _connectionStateSubscription = null;
    _updateStatus(ConnectionStatus.disconnected);
  }

  @override
  Future<void> disconnect() async {
    try {
      await _bleDevice?.disconnect();
    } finally {
      _handleDisconnection();
    }
  }

  @override
  Future<void> write(Uint8List data) async {
    if (_rxCharacteristic == null) {
      throw Exception('Not connected');
    }

    // Write to RX characteristic (device reads from this)
    await _rxCharacteristic!.write(data, withoutResponse: false);
  }

  @override
  void cacheDeviceInfo(DiscoveredDevice device) {
    _scannedDevices[device.id] = device;
    debugLog('[BLE] Cached device info: ${device.name} (${device.id})');
  }

  @override
  Future<void> removeBond(String deviceId) async {
    try {
      final device = fbp.BluetoothDevice.fromId(deviceId);
      debugLog('[BLE] Removing bond for $deviceId');
      await device.removeBond();
      debugLog('[BLE] Bond removed for $deviceId');
    } catch (e) {
      // removeBond may not be supported on all platforms/devices — log and continue
      debugLog('[BLE] removeBond failed (continuing): $e');
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    _scanSubscription?.cancel();
    _notificationSubscription?.cancel();
    _connectionStateSubscription?.cancel();
    _connectionController?.close();
    _dataController?.close();
    _bleDevice?.disconnect();
  }
}
