import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import '../utils/debug_logger_io.dart';

/// Service for detecting internet connectivity
class ConnectivityService {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;

  final _statusController = StreamController<bool>.broadcast();
  bool _hasInternet = true; // Optimistic default
  Timer? _recheckTimer;
  bool _pluginAvailable = true; // Track if native plugin is available

  /// Stream of internet connectivity status changes
  Stream<bool> get internetStream => _statusController.stream;

  /// Current internet connectivity status
  bool get hasInternet => _hasInternet;

  /// Initialize the connectivity service and start monitoring
  Future<void> initialize() async {
    try {
      // Check initial status
      await _checkConnectivity();

      // Listen for changes
      _subscription = _connectivity.onConnectivityChanged.listen((results) {
        _onConnectivityChanged(results);
      });
    } on MissingPluginException catch (e) {
      // Plugin not available (e.g., after hot restart without rebuild)
      debugError('[CONNECTIVITY] Plugin not available: $e');
      _pluginAvailable = false;
      // Fall back to HTTP reachability check only
      await _checkInternetReachability();
    } catch (e) {
      debugError('[CONNECTIVITY] Initialization failed: $e');
      // Keep optimistic default and try HTTP check
      await _checkInternetReachability();
    }
  }

  void _onConnectivityChanged(List<ConnectivityResult> results) {
    final hasNetwork = results.isNotEmpty &&
        !results.contains(ConnectivityResult.none);

    if (hasNetwork) {
      // Network available - verify actual internet reachability
      _checkInternetReachability();
    } else {
      // No network at all
      _updateStatus(false);
    }
  }

  Future<void> _checkConnectivity() async {
    try {
      final results = await _connectivity.checkConnectivity();
      _onConnectivityChanged(results);
    } on MissingPluginException {
      // Plugin not available, fall back to HTTP check
      _pluginAvailable = false;
      await _checkInternetReachability();
    }
  }

  Future<void> _checkInternetReachability() async {
    try {
      // Try to reach MeshMapper API with short timeout
      final response = await http.head(
        Uri.parse('https://yow.meshmapper.net/'),
      ).timeout(const Duration(seconds: 5));

      _updateStatus(response.statusCode < 500);
    } catch (e) {
      debugLog('[CONNECTIVITY] Reachability check failed: $e');
      _updateStatus(false);
    }
  }

  void _updateStatus(bool hasInternet) {
    if (_hasInternet != hasInternet) {
      _hasInternet = hasInternet;
      debugLog('[CONNECTIVITY] Internet status: ${hasInternet ? "available" : "unavailable"}');
      _statusController.add(hasInternet);
    }

    // If no internet OR plugin not available, start periodic recheck via HTTP
    _recheckTimer?.cancel();
    if (!hasInternet || !_pluginAvailable) {
      _recheckTimer = Timer.periodic(const Duration(seconds: 15), (_) {
        _checkInternetReachability();
      });
    }
  }

  /// Force a connectivity recheck
  Future<void> recheck() async {
    await _checkInternetReachability();
  }

  /// Dispose of resources
  void dispose() {
    _subscription?.cancel();
    _recheckTimer?.cancel();
    _statusController.close();
  }
}
