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
  Timer? _pingFlushTimer;
  bool _isUploading = false;
  bool _isRecovering = false;

  // In-memory fallback when Hive is corrupted/unavailable
  final List<ApiQueueItem> _memoryQueue = [];

  // Offline mode
  bool offlineMode = false;
  final List<Map<String, dynamic>> _offlinePings = [];

  // RX buffer for grouping by repeater
  final Map<String, List<ApiQueueItem>> _rxBuffer = {};

  /// Callback for queue updates
  void Function(int queueSize)? onQueueUpdated;

  /// Callback for successful uploads (passes count of items uploaded)
  void Function(int uploadedCount)? onUploadSuccess;

  /// Callback when persistence fails (for user-visible error logging)
  void Function(String errorMessage)? onPersistenceError;

  /// Callback when storage was cleaned up (for user-visible info logging)
  void Function(String infoMessage)? onStorageCleanup;

  /// Number of pings accumulated in current offline session
  int get offlinePingCount => _offlinePings.length;

  ApiQueueService({required ApiService apiService}) : _apiService = apiService;

  /// Initialize the queue (must be called before use)
  Future<void> init() async {
    debugLog('[API QUEUE] init() starting...');

    // Register adapters if not already registered
    debugLog('[API QUEUE] Checking adapter registration...');
    if (!Hive.isAdapterRegistered(3)) {
      debugLog('[API QUEUE] Registering ApiQueueItemAdapter...');
      Hive.registerAdapter(ApiQueueItemAdapter());
    }
    debugLog('[API QUEUE] Adapter check complete');

    // Open Hive box with timeout and recovery
    _box = await _openBoxSafely();

    // ALWAYS START FRESH - clear any leftover pings from previous sessions
    // Pings without a valid session cannot be uploaded, so delete them
    try {
      if (_box != null && _box!.isNotEmpty) {
        debugLog('[API QUEUE] Clearing ${_box!.length} stale items from previous session');
        await _box!.clear();
      }
    } catch (e) {
      debugError('[API QUEUE] Failed to clear stale items: $e - recovering');
      await _recoverBox();
    }
    _memoryQueue.clear();
    _rxBuffer.clear();
    _offlinePings.clear();

    // Start batch timer
    debugLog('[API QUEUE] Starting batch timer...');
    _startBatchTimer();
    debugLog('[API QUEUE] init() complete');
  }

  /// Open Hive box with timeout and automatic recovery from corruption
  Future<Box<ApiQueueItem>?> _openBoxSafely() async {
    const timeout = Duration(seconds: 5);

    debugLog('[API QUEUE] Opening Hive box "$_boxName"...');

    try {
      // First attempt with timeout
      final box = await Hive.openBox<ApiQueueItem>(_boxName).timeout(timeout);
      debugLog('[API QUEUE] Hive box "$_boxName" opened successfully');
      return box;
    } on TimeoutException {
      debugError('[API QUEUE] Hive box "$_boxName" open timed out after ${timeout.inSeconds}s - attempting recovery');
      return _attemptRecovery(timeout);
    } catch (e) {
      debugError('[API QUEUE] Hive box "$_boxName" failed to open: $e - attempting recovery');
      return _attemptRecovery(timeout);
    }
  }

  /// Attempt to recover from Hive corruption by deleting and recreating the box
  Future<Box<ApiQueueItem>?> _attemptRecovery(Duration timeout) async {
    try {
      // Delete the corrupted box
      debugLog('[API QUEUE] Deleting corrupted box "$_boxName"...');
      await Hive.deleteBoxFromDisk(_boxName);
      debugLog('[API QUEUE] Corrupted box deleted, retrying open...');

      // Notify user that cleanup happened
      onStorageCleanup?.call('Queue storage was corrupted and has been reset');

      // Retry opening
      final box = await Hive.openBox<ApiQueueItem>(_boxName).timeout(timeout);
      debugLog('[API QUEUE] Hive box "$_boxName" opened after recovery');
      return box;
    } catch (e) {
      debugError('[API QUEUE] Recovery failed for "$_boxName": $e - operating without persistence');

      // Notify user of persistence failure
      onPersistenceError?.call('Queue storage unavailable - pings will not persist if app closes');

      return null;
    }
  }

  /// Recover from runtime Hive corruption by closing, deleting, and reopening the box
  Future<void> _recoverBox() async {
    if (_isRecovering) {
      debugLog('[API QUEUE] Recovery already in progress, skipping');
      return;
    }
    _isRecovering = true;

    try {
      debugLog('[API QUEUE] Runtime corruption detected - recovering box "$_boxName"...');

      // Close the corrupt box
      try {
        await _box?.close();
      } catch (e) {
        debugWarn('[API QUEUE] Failed to close corrupt box: $e');
      }

      // Delete from disk and reopen
      await Hive.deleteBoxFromDisk(_boxName);
      onStorageCleanup?.call('Queue storage was corrupted and has been reset');

      final box = await Hive.openBox<ApiQueueItem>(_boxName)
          .timeout(const Duration(seconds: 5));
      _box = box;
      debugLog('[API QUEUE] Box recovered successfully');
    } catch (e) {
      debugError('[API QUEUE] Runtime recovery failed: $e - operating without persistence');
      _box = null;
      onPersistenceError?.call('Queue storage unavailable - pings will not persist if app closes');
    } finally {
      _isRecovering = false;
    }
  }

  /// Wrap a write operation with corruption recovery and single retry
  Future<bool> _safeWrite(Future<void> Function(Box<ApiQueueItem> box) operation) async {
    final box = _box;
    if (box == null) return false;

    try {
      await operation(box);
      return true;
    } catch (e) {
      debugError('[API QUEUE] Write failed: $e - attempting recovery');
      await _recoverBox();
      // Retry once after recovery
      final retryBox = _box;
      if (retryBox == null) return false;
      try {
        await operation(retryBox);
        return true;
      } catch (e2) {
        debugError('[API QUEUE] Write failed after recovery: $e2');
        return false;
      }
    }
  }

  /// Wrap a read operation with corruption recovery, returning fallback on failure
  T _safeRead<T>(T Function(Box<ApiQueueItem> box) operation, T fallback) {
    final box = _box;
    if (box == null) return fallback;

    try {
      return operation(box);
    } catch (e) {
      debugError('[API QUEUE] Read failed: $e - scheduling recovery');
      // Schedule async recovery, return fallback immediately
      _recoverBox();
      return fallback;
    }
  }

  /// Get current queue size (Hive + in-memory fallback)
  int get queueSize => _safeRead((box) => box.length, 0) + _memoryQueue.length;

  /// Enqueue a TX ping
  /// heardRepeats format: "4e(12.25),77(12.25)" or "None"
  Future<void> enqueueTx({
    required double latitude,
    required double longitude,
    required String heardRepeats,
    required int timestamp,
    required bool externalAntenna,
    int? noiseFloor,
  }) async {
    final item = ApiQueueItem.fromTx(
      latitude: latitude,
      longitude: longitude,
      heardRepeats: heardRepeats,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] TX enqueued (offline): $heardRepeats');
      return;
    }

    final wrote = await _safeWrite((box) => box.add(item));
    if (!wrote) {
      _memoryQueue.add(item);
      debugLog('[API QUEUE] TX enqueued (memory fallback): $heardRepeats (queue size: $queueSize)');
    } else {
      debugLog('[API QUEUE] TX enqueued: $heardRepeats (queue size: $queueSize)');
    }
    onQueueUpdated?.call(queueSize);
    _pingFlushTimer?.cancel();
    _pingFlushTimer = Timer(const Duration(seconds: 5), () {
      debugLog('[API QUEUE] Ping flush timer fired');
      _flushRxBuffer();
      _uploadBatch();
    });
  }

  /// Enqueue an RX observation
  /// heardRepeats format: "4e(12.0)" (single repeater with SNR)
  Future<void> enqueueRx({
    required double latitude,
    required double longitude,
    required String heardRepeats,
    required int timestamp,
    required String repeaterId,
    required bool externalAntenna,
    int? noiseFloor,
  }) async {
    final item = ApiQueueItem.fromRx(
      latitude: latitude,
      longitude: longitude,
      heardRepeats: heardRepeats,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
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
    required String pubkeyFull,
    required int timestamp,
    required bool externalAntenna,
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
      pubkeyFull: pubkeyFull,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] DISC enqueued (offline): $repeaterId');
      return;
    }

    final wrote = await _safeWrite((box) => box.add(item));
    if (!wrote) {
      _memoryQueue.add(item);
      debugLog('[API QUEUE] DISC enqueued (memory fallback): $repeaterId ($nodeType) at $latitude, $longitude (queue size: $queueSize)');
    } else {
      debugLog('[API QUEUE] DISC enqueued: $repeaterId ($nodeType) at $latitude, $longitude (queue size: $queueSize)');
    }
    onQueueUpdated?.call(queueSize);
    _pingFlushTimer?.cancel();
    _pingFlushTimer = Timer(const Duration(seconds: 5), () {
      debugLog('[API QUEUE] Ping flush timer fired');
      _flushRxBuffer();
      _uploadBatch();
    });
  }

  /// Enqueue a failed DISC discovery (no nodes responded)
  Future<void> enqueueDiscDrop({
    required double latitude,
    required double longitude,
    required int timestamp,
    required bool externalAntenna,
    int? noiseFloor,
  }) async {
    final item = ApiQueueItem.fromDiscDrop(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] DISC drop enqueued (offline)');
      return;
    }

    final wrote = await _safeWrite((box) => box.add(item));
    if (!wrote) {
      _memoryQueue.add(item);
      debugLog('[API QUEUE] DISC drop enqueued (memory fallback) at $latitude, $longitude (queue size: $queueSize)');
    } else {
      debugLog('[API QUEUE] DISC drop enqueued at $latitude, $longitude (queue size: $queueSize)');
    }
    onQueueUpdated?.call(queueSize);
    _pingFlushTimer?.cancel();
    _pingFlushTimer = Timer(const Duration(seconds: 5), () {
      debugLog('[API QUEUE] Ping flush timer fired');
      _flushRxBuffer();
      _uploadBatch();
    });
  }

  // Guard to prevent concurrent RX buffer flushes
  bool _isFlushing = false;

  /// Flush RX buffer to main queue
  Future<void> _flushRxBuffer() async {
    // Return early if buffer is empty or flush already in progress
    if (_rxBuffer.isEmpty || _isFlushing) return;
    _isFlushing = true;

    try {
      // Make a copy of the buffer and clear it immediately
      // This prevents concurrent calls from trying to add the same items twice
      final itemsToFlush = <ApiQueueItem>[];
      for (final items in _rxBuffer.values) {
        itemsToFlush.addAll(items);
      }
      final bufferSize = _rxBuffer.length;
      _rxBuffer.clear();

      // Now add items to the box (or memory fallback)
      for (final item in itemsToFlush) {
        final ok = await _safeWrite((box) => box.add(item));
        if (!ok) {
          _memoryQueue.add(item);
        }
      }

      debugLog('[API QUEUE] Flushed ${itemsToFlush.length} RX items from $bufferSize repeaters to queue');
      onQueueUpdated?.call(queueSize);
    } finally {
      _isFlushing = false;
    }
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

  /// Manually flush queue (called by TX-triggered flush timer)
  Future<void> flushQueue() async {
    await _flushRxBuffer();
    await _uploadBatch();
  }

  /// Upload batch of queued items (from Hive box or in-memory fallback)
  Future<void> _uploadBatch() async {
    if (_isUploading) {
      debugLog('[API QUEUE] Upload skipped: already uploading');
      return;
    }

    final hiveEmpty = _safeRead((box) => box.isEmpty, true);
    final memoryEmpty = _memoryQueue.isEmpty;

    if (hiveEmpty && memoryEmpty) {
      debugLog('[API QUEUE] Upload skipped: queue empty');
      return;
    }

    _isUploading = true;

    try {
      // Collect items from both Hive and memory queue
      final hiveItems = _safeRead((box) => box.values
          .where((item) =>
              item.retryCount < _maxRetries &&
              item.isReadyForRetry &&
              item.isUploadEligible)
          .take(_batchSize)
          .toList(), <ApiQueueItem>[]);

      final memoryItems = _memoryQueue
          .where((item) =>
              item.retryCount < _maxRetries &&
              item.isReadyForRetry &&
              item.isUploadEligible)
          .take(_batchSize - hiveItems.length)
          .toList();

      final items = [...hiveItems, ...memoryItems];

      if (items.isEmpty) {
        debugLog('[API QUEUE] Upload skipped: no items ready for upload');
        _isUploading = false;
        return;
      }

      // Convert to API format
      final pings = items.map((item) => item.toApiJson()).toList();

      // Log each item with external_antenna value
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        debugLog('[API QUEUE] Item ${i + 1}/${items.length}: type=${item.type}, external_antenna=${item.externalAntenna}');
      }

      final memoryCount = memoryItems.length;
      if (memoryCount > 0) {
        debugLog('[API QUEUE] Uploading ${items.length} items ($memoryCount from memory fallback)...');
      } else {
        debugLog('[API QUEUE] Uploading ${items.length} items...');
      }

      // Attempt upload
      final result = await _apiService.uploadBatch(pings);

      if (result == UploadResult.success) {
        final uploadedCount = items.length;
        // Remove successful Hive items
        for (final item in hiveItems) {
          try { await item.delete(); } catch (_) {}
        }
        // Remove successful memory items
        for (final item in memoryItems) {
          _memoryQueue.remove(item);
        }
        debugLog('[API QUEUE] Upload SUCCESS: deleted $uploadedCount items');
        onUploadSuccess?.call(uploadedCount);
      } else if (result == UploadResult.nonRetryable) {
        // Data is permanently invalid — discard
        for (final item in hiveItems) {
          try { await item.delete(); } catch (_) {}
        }
        for (final item in memoryItems) {
          _memoryQueue.remove(item);
        }
        debugWarn('[API QUEUE] Discarded ${items.length} items (non-retryable error)');
      } else {
        // Mark items as retried
        for (final item in hiveItems) {
          item.markRetried();
        }
        // Memory items: update retry fields directly (no Hive save)
        for (final item in memoryItems) {
          item.retryCount++;
          item.lastRetryAt = DateTime.now();
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

  /// Force upload all queued items immediately
  /// Used during BLE disconnect to ensure all data is uploaded before session release
  Future<void> forceUploadWithHoldWait() async {
    _pingFlushTimer?.cancel();
    await _flushRxBuffer();
    await _uploadBatch();
  }

  /// Clear all queued items
  Future<void> clear() async {
    await _safeWrite((box) => box.clear());
    _memoryQueue.clear();
    _rxBuffer.clear();
    onQueueUpdated?.call(0);
  }

  /// Clear queue on disconnect - ALWAYS START FRESH
  /// Called when device disconnects to ensure no stale pings remain
  /// Also stops the batch timer to prevent upload attempts without a session
  Future<void> clearOnDisconnect() async {
    // Stop timers to prevent upload attempts without session
    _batchTimer?.cancel();
    _batchTimer = null;
    _pingFlushTimer?.cancel();
    _pingFlushTimer = null;
    debugLog('[API QUEUE] Timers stopped on disconnect');

    final count = queueSize + _rxBuffer.length;
    if (count > 0) {
      debugLog('[API QUEUE] Clearing $count items on disconnect (queue: $queueSize, rxBuffer: ${_rxBuffer.length})');
    }
    await _safeWrite((box) => box.clear());
    _memoryQueue.clear();
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
    await _safeWrite((box) => box.clear());
    _memoryQueue.clear();
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
    final hiveItems = _safeRead(
      (box) => box.values.where((item) => item.retryCount >= _maxRetries).toList(),
      <ApiQueueItem>[],
    );
    final memoryItems = _memoryQueue.where((item) => item.retryCount >= _maxRetries).toList();
    return [...hiveItems, ...memoryItems];
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
    _pingFlushTimer?.cancel();
    _box?.close();
  }
}
