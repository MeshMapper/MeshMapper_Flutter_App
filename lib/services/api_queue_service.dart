import 'dart:async';

import 'package:hive/hive.dart';

import '../models/api_queue_item.dart';
import '../utils/debug_logger_io.dart';
import 'api_service.dart';

/// API queue service with batch upload and retry logic
/// Ported from apiQueue and batchUpload() in wardrive.js
///
/// Features:
/// - Queue pings locally with Hive persistence
/// - Batch upload every 50 entries OR 30 seconds
/// - RX buffering: group by repeater ID (max 4 per batch)
/// - Retry with exponential backoff for failed uploads
/// - Offline mode: accumulates pings without uploading
class ApiQueueService {
  static const String _boxName = 'api_queue';
  static const int _batchSize = 50;
  static const Duration _batchTimeout = Duration(seconds: 15);
  static const int _maxRetries = 5;
  static const int _maxRxPerRepeater = 4;

  final ApiService _apiService;
  Box<ApiQueueItem>? _box;
  Timer? _batchTimer;
  bool _isUploading = false;

  // Offline mode
  bool offlineMode = false;
  final List<Map<String, dynamic>> _offlinePings = [];

  // RX buffer for grouping by repeater
  final Map<String, List<ApiQueueItem>> _rxBuffer = {};

  /// Callback for queue updates
  void Function(int queueSize)? onQueueUpdated;

  /// Callback for successful uploads (passes count of items uploaded)
  void Function(int uploadedCount)? onUploadSuccess;

  /// Number of pings accumulated in current offline session
  int get offlinePingCount => _offlinePings.length;

  ApiQueueService({required ApiService apiService}) : _apiService = apiService;

  /// Initialize the queue (must be called before use)
  Future<void> init() async {
    // Register adapters if not already registered
    if (!Hive.isAdapterRegistered(3)) {
      Hive.registerAdapter(ApiQueueItemAdapter());
    }

    _box = await Hive.openBox<ApiQueueItem>(_boxName);

    // ALWAYS START FRESH - clear any leftover pings from previous sessions
    // Pings without a valid session cannot be uploaded, so delete them
    if (_box!.isNotEmpty) {
      debugLog('[API QUEUE] Clearing ${_box!.length} stale items from previous session');
      await _box!.clear();
    }
    _rxBuffer.clear();
    _offlinePings.clear();

    // Start batch timer
    _startBatchTimer();
  }

  /// Get current queue size
  int get queueSize => _box?.length ?? 0;

  /// Enqueue a TX ping
  /// heardRepeats format: "4e(12.25),77(12.25)" or "None"
  Future<void> enqueueTx({
    required double latitude,
    required double longitude,
    required String heardRepeats,
    required int timestamp,
    int? noiseFloor,
  }) async {
    final item = ApiQueueItem.fromTx(
      latitude: latitude,
      longitude: longitude,
      heardRepeats: heardRepeats,
      timestamp: timestamp,
      noiseFloor: noiseFloor,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] TX enqueued (offline): $heardRepeats');
      return;
    }

    await _box?.add(item);
    debugLog('[API QUEUE] TX enqueued: $heardRepeats (queue size: $queueSize)');
    onQueueUpdated?.call(queueSize);
    _checkBatchUpload();
  }

  /// Enqueue an RX observation
  /// heardRepeats format: "4e(12.0)" (single repeater with SNR)
  Future<void> enqueueRx({
    required double latitude,
    required double longitude,
    required String heardRepeats,
    required int timestamp,
    required String repeaterId,
    int? noiseFloor,
  }) async {
    final item = ApiQueueItem.fromRx(
      latitude: latitude,
      longitude: longitude,
      heardRepeats: heardRepeats,
      timestamp: timestamp,
      noiseFloor: noiseFloor,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      _offlinePings.add(item.toApiJson());
      return;
    }

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

  /// Enqueue a DISC discovery observation
  /// Each discovered node is queued separately
  Future<void> enqueueDisc({
    required double latitude,
    required double longitude,
    required String repeaterId,
    required String nodeType,
    required double localSnr,
    required int localRssi,
    required double remoteSnr,
    required int timestamp,
    int? noiseFloor,
  }) async {
    final item = ApiQueueItem.fromDisc(
      latitude: latitude,
      longitude: longitude,
      repeaterId: repeaterId,
      nodeType: nodeType,
      localSnr: localSnr,
      localRssi: localRssi,
      remoteSnr: remoteSnr,
      timestamp: timestamp,
      noiseFloor: noiseFloor,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] DISC enqueued (offline): $repeaterId');
      return;
    }

    await _box?.add(item);
    debugLog('[API QUEUE] DISC enqueued: $repeaterId ($nodeType) at $latitude, $longitude (queue size: $queueSize)');
    onQueueUpdated?.call(queueSize);
    _checkBatchUpload();
  }

  /// Flush RX buffer to main queue
  Future<void> _flushRxBuffer() async {
    // Return early if buffer is empty (avoids concurrent flush issues)
    if (_rxBuffer.isEmpty) return;

    // Make a copy of the buffer and clear it immediately
    // This prevents concurrent calls from trying to add the same items twice
    final itemsToFlush = <ApiQueueItem>[];
    for (final items in _rxBuffer.values) {
      itemsToFlush.addAll(items);
    }
    final bufferSize = _rxBuffer.length;
    _rxBuffer.clear();

    // Now add items to the box
    for (final item in itemsToFlush) {
      await _box?.add(item);
    }

    debugLog('[API QUEUE] Flushed ${itemsToFlush.length} RX items from $bufferSize repeaters to queue');
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
      debugLog('[API QUEUE] Batch timer fired (15s interval)');
      _flushRxBuffer();
      _uploadBatch();
    });
  }

  void _checkBatchUpload() {
    if (queueSize >= _batchSize) {
      _uploadBatch();
    }
  }

  /// Manually flush queue (called by TX-triggered flush timer)
  Future<void> flushQueue() async {
    await _flushRxBuffer();
    await _uploadBatch();
  }

  /// Upload batch of queued items
  Future<void> _uploadBatch() async {
    if (_isUploading) {
      debugLog('[API QUEUE] Upload skipped: already uploading');
      return;
    }
    if (_box == null || _box!.isEmpty) {
      debugLog('[API QUEUE] Upload skipped: queue empty');
      return;
    }

    _isUploading = true;

    try {
      // Get items ready for retry
      final items = _box!.values
          .where((item) => item.retryCount < _maxRetries && item.isReadyForRetry)
          .take(_batchSize)
          .toList();

      if (items.isEmpty) {
        debugLog('[API QUEUE] Upload skipped: no items ready for upload');
        _isUploading = false;
        return;
      }

      // Convert to API format
      final pings = items.map((item) => item.toApiJson()).toList();

      debugLog('[API QUEUE] Uploading ${items.length} items...');

      // Attempt upload
      final success = await _apiService.uploadBatch(pings);

      if (success) {
        final uploadedCount = items.length;
        // Remove successful items
        for (final item in items) {
          await item.delete();
        }
        debugLog('[API QUEUE] Upload SUCCESS: deleted $uploadedCount items');
        onUploadSuccess?.call(uploadedCount);
      } else {
        // Mark items as retried
        for (final item in items) {
          item.markRetried();
        }
        debugLog('[API QUEUE] Upload FAILED: ${items.length} items marked for retry');
      }

      onQueueUpdated?.call(queueSize);
    } catch (e) {
      debugError('[API QUEUE] Upload exception: $e');
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

  /// Clear queue on disconnect - ALWAYS START FRESH
  /// Called when device disconnects to ensure no stale pings remain
  /// Also stops the batch timer to prevent upload attempts without a session
  Future<void> clearOnDisconnect() async {
    // Stop the batch timer to prevent upload attempts without session
    _batchTimer?.cancel();
    _batchTimer = null;
    debugLog('[API QUEUE] Batch timer stopped on disconnect');

    final count = queueSize + _rxBuffer.length;
    if (count > 0) {
      debugLog('[API QUEUE] Clearing $count items on disconnect (queue: $queueSize, rxBuffer: ${_rxBuffer.length})');
    }
    await _box?.clear();
    _rxBuffer.clear();
    onQueueUpdated?.call(0);
  }

  /// Clear queue before connecting - ALWAYS START FRESH
  /// Called before establishing a new connection
  /// Also restarts the batch timer if it was stopped
  Future<void> clearBeforeConnect() async {
    final count = queueSize + _rxBuffer.length;
    if (count > 0) {
      debugLog('[API QUEUE] Clearing $count stale items before connect');
    }
    await _box?.clear();
    _rxBuffer.clear();
    onQueueUpdated?.call(0);

    // Restart batch timer if it was stopped
    if (_batchTimer == null) {
      debugLog('[API QUEUE] Restarting batch timer on connect');
      _startBatchTimer();
    }
  }

  /// Get failed items (exceeded max retries)
  List<ApiQueueItem> get failedItems {
    return _box?.values
        .where((item) => item.retryCount >= _maxRetries)
        .toList() ?? [];
  }

  /// Get accumulated offline pings and clear the accumulator
  /// Returns the list of ping JSON objects collected during offline session
  List<Map<String, dynamic>> getAndClearOfflinePings() {
    final pings = List<Map<String, dynamic>>.from(_offlinePings);
    _offlinePings.clear();
    return pings;
  }

  /// Clear offline pings without returning them
  void clearOfflinePings() {
    _offlinePings.clear();
  }

  /// Dispose of resources
  void dispose() {
    _batchTimer?.cancel();
    _box?.close();
  }
}
