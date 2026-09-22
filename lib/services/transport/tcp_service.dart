import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/debug_logger_io.dart';
import '../bluetooth/bluetooth_service.dart';
import 'stream_transport_base.dart';

/// Saved TCP connection for quick reconnect.
class SavedTcpConnection {
  final String id;
  final String host;
  final int port;
  final String name;
  final DateTime lastConnected;

  const SavedTcpConnection({
    required this.id,
    required this.host,
    required this.port,
    required this.name,
    required this.lastConnected,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'host': host,
        'port': port,
        'name': name,
        'lastConnected': lastConnected.toIso8601String(),
      };

  factory SavedTcpConnection.fromJson(Map<String, dynamic> json) {
    return SavedTcpConnection(
      id: json['id'] as String,
      host: json['host'] as String,
      port: json['port'] as int,
      name: json['name'] as String,
      lastConnected: DateTime.parse(json['lastConnected'] as String),
    );
  }
}

/// TCP transport for MeshCore companion connections.
///
/// Connects to a MeshCore device via raw TCP socket (default port 5000).
/// Available on Android, iOS, and Desktop (NOT web — browsers cannot
/// open raw TCP sockets).
class TcpService extends StreamTransportBase {
  final String host;
  final int port;

  Socket? _socket;
  StreamSubscription? _socketSubscription;

  TcpService({required this.host, this.port = 5000});

  @override
  Future<void> openConnection() async {
    debugLog('[CONN] TCP connecting to $host:$port');
    setConnecting();

    try {
      _socket = await Socket.connect(host, port,
          timeout: const Duration(seconds: 10));
      _socket!.setOption(SocketOption.tcpNoDelay, true);
      debugLog('[CONN] TCP connected to $host:$port');

      setConnected(DiscoveredDevice(
        id: '$host:$port',
        name: 'TCP $host:$port',
      ));

      _socketSubscription = _socket!.listen(
        (data) => onRawBytesReceived(Uint8List.fromList(data)),
        onError: (error) {
          debugError('[CONN] TCP socket error: $error');
          setDisconnected();
        },
        onDone: () {
          debugLog('[CONN] TCP socket closed by remote');
          setDisconnected();
        },
      );
    } catch (e) {
      debugError('[CONN] TCP connection failed: $e');
      setError();
      rethrow;
    }
  }

  @override
  Future<void> writeRawBytes(Uint8List data) async {
    _socket?.add(data);
  }

  @override
  Future<void> closeConnection() async {
    _socketSubscription?.cancel();
    _socketSubscription = null;
    _socket?.destroy();
    _socket = null;
    debugLog('[CONN] TCP connection closed');
  }

  @override
  void dispose() {
    _socketSubscription?.cancel();
    _socket?.destroy();
    super.dispose();
  }

  // --- Saved connections persistence ---

  static const _prefsKey = 'saved_tcp_connections';

  static Future<List<SavedTcpConnection>> getSavedConnections() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_prefsKey);
    if (jsonString == null) return [];

    try {
      final list = jsonDecode(jsonString) as List;
      return list
          .map((e) => SavedTcpConnection.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.lastConnected.compareTo(a.lastConnected));
    } catch (e) {
      debugError('[CONN] Failed to load saved TCP connections: $e');
      return [];
    }
  }

  static Future<void> saveConnection(String host, int port, String name) async {
    final prefs = await SharedPreferences.getInstance();
    final connections = await getSavedConnections();

    final id = '$host:$port';
    connections.removeWhere((c) => c.id == id);
    connections.insert(
        0,
        SavedTcpConnection(
          id: id,
          host: host,
          port: port,
          name: name.isEmpty ? 'TCP $host:$port' : name,
          lastConnected: DateTime.now(),
        ));

    final jsonString = jsonEncode(connections.map((c) => c.toJson()).toList());
    await prefs.setString(_prefsKey, jsonString);
  }

  static Future<void> deleteConnection(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final connections = await getSavedConnections();
    connections.removeWhere((c) => c.id == id);

    final jsonString = jsonEncode(connections.map((c) => c.toJson()).toList());
    await prefs.setString(_prefsKey, jsonString);
  }
}
