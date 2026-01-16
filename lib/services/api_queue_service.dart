import 'dart:async';

import 'package:hive/hive.dart';

import '../models/api_queue_item.dart';
import 'api_service.dart';

/// API queue service with batch upload and retry logic
/// Ported from apiQueue and batchUpload() in wardrive.js
/// 
/// Features:
/// - Queue pings locally with Hive persistence
/// - Batch upload every 10 entries OR 30 seconds
/// - RX buffering: group by repeater ID (max 4 per batch)
/// - Retry with exponential backoff for failed uploads
class ApiQueueService {
  static const String _boxName = 'api_queue';
  static const int _batchSize = 10;
  static const Duration _batchTimeout = Duration(seconds: 30);
  static const int _maxRetries = 5;
  static const int _maxRxPerRepeater = 4;

  final ApiService _apiService;
  Box<ApiQueueItem>? _box;
  Timer? _batchTimer;
  bool _isUploading = false;

  // RX buffer for grouping by repeater
  final Map<String, List<ApiQueueItem>> _rxBuffer = {};

  /// Callback for queue updates
  void Function(int queueSize)? onQueueUpdated;

  ApiQueueService({required ApiService apiService}) : _apiService = apiService;

  /// Initialize the queue (must be called before use)
  Future<void> init() async {
    // Register adapters if not already registered
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(ApiQueueItemAdapter());
    }
    
    _box = await Hive.openBox<ApiQueueItem>(_boxName);
    
    // Start batch timer
    _startBatchTimer();
  }

  /// Get current queue size
  int get queueSize => _box?.length ?? 0;

  /// Enqueue a TX ping
  Future<void> enqueueTx({
    required double latitude,
    required double longitude,
    required int power,
    required String deviceId,
  }) async {
    final item = ApiQueueItem.fromTx(
      latitude: latitude,
      longitude: longitude,
      power: power,
      deviceId: deviceId,
    );
    
    await _box?.add(item);
    onQueueUpdated?.call(queueSize);
    _checkBatchUpload();
  }

  /// Enqueue an RX ping (buffered by repeater)
  Future<void> enqueueRx({
    required double latitude,
    required double longitude,
    required String repeaterId,
    required double snr,
    required int rssi,
    required String deviceId,
  }) async {
    final item = ApiQueueItem.fromRx(
      latitude: latitude,
      longitude: longitude,
      repeaterId: repeaterId,
      snr: snr,
      rssi: rssi,
      deviceId: deviceId,
    );

    // Buffer RX pings by repeater (max 4 per batch)
    if (!_rxBuffer.containsKey(repeaterId)) {
      _rxBuffer[repeaterId] = [];
    }
    
    if (_rxBuffer[repeaterId]!.length < _maxRxPerRepeater) {
      _rxBuffer[repeaterId]!.add(item);
    }
    
    // Check if we should flush RX buffer
    _checkRxBufferFlush();
  }

  /// Flush RX buffer to main queue
  Future<void> _flushRxBuffer() async {
    for (final items in _rxBuffer.values) {
      for (final item in items) {
        await _box?.add(item);
      }
    }
    _rxBuffer.clear();
    onQueueUpdated?.call(queueSize);
  }

  void _checkRxBufferFlush() {
    // Flush if any repeater has max items
    for (final items in _rxBuffer.values) {
      if (items.length >= _maxRxPerRepeater) {
        _flushRxBuffer();
        return;
      }
    }
  }

  void _startBatchTimer() {
    _batchTimer?.cancel();
    _batchTimer = Timer.periodic(_batchTimeout, (_) {
      _flushRxBuffer();
      _uploadBatch();
    });
  }

  void _checkBatchUpload() {
    if (queueSize >= _batchSize) {
      _uploadBatch();
    }
  }

  /// Upload batch of queued items
  Future<void> _uploadBatch() async {
    if (_isUploading || _box == null || _box!.isEmpty) return;
    
    _isUploading = true;

    try {
      // Get items ready for retry
      final items = _box!.values
          .where((item) => item.retryCount < _maxRetries && item.isReadyForRetry)
          .take(_batchSize)
          .toList();

      if (items.isEmpty) {
        _isUploading = false;
        return;
      }

      // Convert to API format
      final pings = items.map((item) => item.toApiJson()).toList();

      // Attempt upload
      final success = await _apiService.uploadBatch(pings);

      if (success) {
        // Remove successful items
        for (final item in items) {
          await item.delete();
        }
      } else {
        // Mark items as retried
        for (final item in items) {
          item.markRetried();
        }
      }

      onQueueUpdated?.call(queueSize);
    } catch (e) {
      // Retry later
    } finally {
      _isUploading = false;
    }
  }

  /// Force upload all queued items
  Future<void> forceUpload() async {
    await _flushRxBuffer();
    await _uploadBatch();
  }

  /// Clear all queued items
  Future<void> clear() async {
    await _box?.clear();
    _rxBuffer.clear();
    onQueueUpdated?.call(0);
  }

  /// Get failed items (exceeded max retries)
  List<ApiQueueItem> get failedItems {
    return _box?.values
        .where((item) => item.retryCount >= _maxRetries)
        .toList() ?? [];
  }

  /// Dispose of resources
  void dispose() {
    _batchTimer?.cancel();
    _box?.close();
  }
}
