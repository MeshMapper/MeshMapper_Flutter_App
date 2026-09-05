import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/api_queue_item.dart';
import '../utils/debug_logger_io.dart';
import 'api_service.dart';
import 'custom_api_service.dart';

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

  /// Airborne block for Offline Mode. While set, accepted fixes are NOT
  /// appended to the offline recording: an offline upload is the one path
  /// that could carry in-flight rows to the server after the forced app
  /// upgrade (the online queue is dropped by the session end), and the server
  /// owner chose the app as the only control on it. Driven by the provider on
  /// every latch flip; logged once on pause and once on resume, never per row.
  bool _offlineRecordingPaused = false;
  int _offlineRowsDroppedWhilePaused = 0;

  // RX buffer for grouping by repeater
  final Map<String, List<ApiQueueItem>> _rxBuffer = {};

  /// Callback for queue updates
  void Function(int queueSize)? onQueueUpdated;

  /// Callback for successful uploads. Passes the count AND the uploaded items
  /// so the listener can compute which coverage tiles the batch touched (the
  /// post-wardrive vector tile refresh needs the ping coordinates).
  void Function(int uploadedCount, List<ApiQueueItem> uploadedItems)?
      onUploadSuccess;

  /// Callback when persistence fails (for user-visible error logging)
  void Function(String errorMessage)? onPersistenceError;

  /// Callback when storage was cleaned up (for user-visible info logging)
  void Function(String infoMessage)? onStorageCleanup;

  /// Custom API service for forwarding pings to third-party endpoint
  CustomApiService? customApiService;

  /// Number of pings accumulated in current offline session
  int get offlinePingCount => _offlinePings.length;

  /// Whether the airborne pause is holding the offline recording.
  bool get isOfflineRecordingPaused => _offlineRecordingPaused;

  /// Pause or resume the offline recording (see [_offlineRecordingPaused]).
  void setOfflineRecordingPaused(bool paused) {
    if (paused == _offlineRecordingPaused) return;
    _offlineRecordingPaused = paused;
    if (paused) {
      _offlineRowsDroppedWhilePaused = 0;
      if (offlineMode) {
        debugWarn(
            '[OFFLINE] Recording paused: airborne (no rows until the latch clears)');
      }
    } else if (offlineMode) {
      debugLog(
          '[OFFLINE] Recording resumed ($_offlineRowsDroppedWhilePaused rows dropped while airborne)');
    }
  }

  /// True when the airborne pause swallowed this offline row.
  bool _dropOfflineRowIfPaused() {
    if (!_offlineRecordingPaused) return false;
    _offlineRowsDroppedWhilePaused++;
    return true;
  }

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
        debugLog(
            '[API QUEUE] Clearing ${_box!.length} stale items from previous session');
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
      debugError(
          '[API QUEUE] Hive box "$_boxName" open timed out after ${timeout.inSeconds}s - attempting recovery');
      return _attemptRecovery(timeout);
    } catch (e) {
      debugError(
          '[API QUEUE] Hive box "$_boxName" failed to open: $e - attempting recovery');
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
      debugError(
          '[API QUEUE] Recovery failed for "$_boxName": $e - operating without persistence');

      // Notify user of persistence failure
      onPersistenceError?.call(
          'Queue storage unavailable - pings will not persist if app closes');

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
      debugLog(
          '[API QUEUE] Runtime corruption detected - recovering box "$_boxName"...');

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
      debugError(
          '[API QUEUE] Runtime recovery failed: $e - operating without persistence');
      _box = null;
      onPersistenceError?.call(
          'Queue storage unavailable - pings will not persist if app closes');
    } finally {
      _isRecovering = false;
    }
  }

  /// Wrap a write operation with corruption recovery and single retry
  Future<bool> _safeWrite(
      Future<void> Function(Box<ApiQueueItem> box) operation) async {
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
    double? power,
    int? pingCounter,
    String? wireTag,
    double? altitude,
  }) async {
    final item = ApiQueueItem.fromTx(
      latitude: latitude,
      longitude: longitude,
      heardRepeats: heardRepeats,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
      pingCounter: pingCounter,
      wireTag: wireTag,
      altitude: altitude,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      if (_dropOfflineRowIfPaused()) return;
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] TX enqueued (offline): $heardRepeats');
      return;
    }

    final wrote = await _safeWrite((box) => box.add(item));
    if (!wrote) {
      _memoryQueue.add(item);
      debugLog(
          '[API QUEUE] TX enqueued (memory fallback): $heardRepeats (queue size: $queueSize)');
    } else {
      debugLog(
          '[API QUEUE] TX enqueued: $heardRepeats (queue size: $queueSize)');
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
    double? power,
    double? altitude,
  }) async {
    final item = ApiQueueItem.fromRx(
      latitude: latitude,
      longitude: longitude,
      heardRepeats: heardRepeats,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
      altitude: altitude,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      if (_dropOfflineRowIfPaused()) return;
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
    double? power,
    double? altitude,
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
      power: power,
      altitude: altitude,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      if (_dropOfflineRowIfPaused()) return;
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] DISC enqueued (offline): $repeaterId');
      return;
    }

    final wrote = await _safeWrite((box) => box.add(item));
    if (!wrote) {
      _memoryQueue.add(item);
      debugLog(
          '[API QUEUE] DISC enqueued (memory fallback): $repeaterId ($nodeType) at $latitude, $longitude (queue size: $queueSize)');
    } else {
      debugLog(
          '[API QUEUE] DISC enqueued: $repeaterId ($nodeType) at $latitude, $longitude (queue size: $queueSize)');
    }
    onQueueUpdated?.call(queueSize);
    _pingFlushTimer?.cancel();
    _pingFlushTimer = Timer(const Duration(seconds: 5), () {
      debugLog('[API QUEUE] Ping flush timer fired');
      _flushRxBuffer();
      _uploadBatch();
    });
  }

  /// Enqueue a TRACE ping result (targeted zero-hop trace)
  Future<void> enqueueTrace({
    required double latitude,
    required double longitude,
    required String repeaterId,
    required double localSnr,
    required int localRssi,
    required double remoteSnr,
    required int timestamp,
    required bool externalAntenna,
    int? noiseFloor,
    double? power,
    double? altitude,
  }) async {
    final item = ApiQueueItem.fromTrace(
      latitude: latitude,
      longitude: longitude,
      repeaterId: repeaterId,
      localSnr: localSnr,
      localRssi: localRssi,
      remoteSnr: remoteSnr,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
      altitude: altitude,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      if (_dropOfflineRowIfPaused()) return;
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] TRACE enqueued (offline): $repeaterId');
      return;
    }

    final wrote = await _safeWrite((box) => box.add(item));
    if (!wrote) {
      _memoryQueue.add(item);
      debugLog(
          '[API QUEUE] TRACE enqueued (memory fallback): $repeaterId at $latitude, $longitude (queue size: $queueSize)');
    } else {
      debugLog(
          '[API QUEUE] TRACE enqueued: $repeaterId at $latitude, $longitude (queue size: $queueSize)');
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
    double? power,
    double? altitude,
  }) async {
    final item = ApiQueueItem.fromDiscDrop(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
      altitude: altitude,
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      if (_dropOfflineRowIfPaused()) return;
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] DISC drop enqueued (offline)');
      return;
    }

    final wrote = await _safeWrite((box) => box.add(item));
    if (!wrote) {
      _memoryQueue.add(item);
      debugLog(
          '[API QUEUE] DISC drop enqueued (memory fallback) at $latitude, $longitude (queue size: $queueSize)');
    } else {
      debugLog(
          '[API QUEUE] DISC drop enqueued at $latitude, $longitude (queue size: $queueSize)');
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

      debugLog(
          '[API QUEUE] Flushed ${itemsToFlush.length} RX items from $bufferSize repeaters to queue');
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
      final hiveItems = _safeRead(
          (box) => box.values
              .where((item) =>
                  item.retryCount < _maxRetries &&
                  item.isReadyForRetry &&
                  item.isUploadEligible)
              .take(_batchSize)
              .toList(),
          <ApiQueueItem>[]);

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

      // Log each item with external_antenna value. Token-mode TX entries also log their
      // wire_tag + ping_counter so a debug log self-documents any tag collision/drop.
      for (int i = 0; i < items.length; i++) {
        final item = items[i];
        final tagInfo = item.wireTag != null
            ? ', wire_tag=${item.wireTag}, ping_counter=${item.pingCounter}'
            : '';
        debugLog(
            '[API QUEUE] Item ${i + 1}/${items.length}: type=${item.type}, external_antenna=${item.externalAntenna}$tagInfo');
      }

      final memoryCount = memoryItems.length;
      if (memoryCount > 0) {
        debugLog(
            '[API QUEUE] Uploading ${items.length} items ($memoryCount from memory fallback)...');
      } else {
        debugLog('[API QUEUE] Uploading ${items.length} items...');
      }

      // Attempt upload
      final result = await _apiService.uploadBatch(pings);

      if (result == UploadResult.success) {
        final uploadedCount = items.length;
        // Remove successful Hive items
        for (final item in hiveItems) {
          try {
            await item.delete();
          } catch (_) {}
        }
        // Remove successful memory items
        for (final item in memoryItems) {
          _memoryQueue.remove(item);
        }
        debugLog('[API QUEUE] Upload SUCCESS: deleted $uploadedCount items');
        // The network is demonstrably back, so give anything the ladder has
        // already written off one more chance.
        _reviveFailedItems();
        onUploadSuccess?.call(uploadedCount, items);
        // Fire-and-forget: forward to custom API endpoint
        customApiService?.forwardPings(pings);
      } else if (result == UploadResult.nonRetryable) {
        // Data is permanently invalid — discard
        for (final item in hiveItems) {
          try {
            await item.delete();
          } catch (_) {}
        }
        for (final item in memoryItems) {
          _memoryQueue.remove(item);
        }
        debugWarn(
            '[API QUEUE] Discarded ${items.length} items (non-retryable error)');
      } else if (result == UploadResult.unreachable) {
        // We never got an answer, so this says nothing about the data. Leave
        // retryCount and lastRetryAt alone: spending a retry here meant ~75s
        // out of coverage wrote every queued ping off for good (#437). The
        // flush cadence is the pacing; there is nothing to back off from.
        debugLog(
            '[API QUEUE] Upload deferred: ${items.length} items held, no route to server');
      } else if (result == UploadResult.held) {
        // The server's storm brake is running for this session and named its
        // own wait; the batch never left. Same rule as unreachable: no retry
        // spent, the timer comes back once the hold has run.
        debugLog(
            '[API QUEUE] Upload held: ${items.length} items wait out the server backoff');
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
        debugLog(
            '[API QUEUE] Upload FAILED: ${items.length} items marked for retry');
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
      debugLog(
          '[API QUEUE] Clearing $count items on disconnect (queue: $queueSize, rxBuffer: ${_rxBuffer.length})');
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

  /// Put items the retry ladder has written off back in the running.
  ///
  /// Called after a successful upload, which is the only proof we have that the
  /// server is reachable and answering. Without it [_maxRetries] is a one-way
  /// door: nothing resets the counter, so a written-off ping sat in Hive
  /// forever, never uploaded and never surfaced (#437).
  ///
  /// Only items past the ladder are touched. Anything still climbing it is
  /// mid-backoff for a reason the server gave us, and is left alone.
  void _reviveFailedItems() {
    final stranded = failedItems;
    if (stranded.isEmpty) return;

    for (final item in stranded) {
      item.retryCount = 0;
      item.lastRetryAt = null;
      if (item.isInBox) {
        try {
          item.save();
        } catch (_) {}
      }
    }
    debugLog('[API QUEUE] Revived ${stranded.length} items the retry ladder '
        'had written off');
  }

  /// Every item currently held, Hive and memory alike.
  ///
  /// Exists so tests can set an item's retry state directly instead of spending
  /// 31 seconds of real time climbing the backoff ladder to reach it.
  @visibleForTesting
  List<ApiQueueItem> get heldItems => [
        ..._safeRead((box) => box.values.toList(), <ApiQueueItem>[]),
        ..._memoryQueue,
      ];

  /// Get failed items (exceeded max retries)
  List<ApiQueueItem> get failedItems {
    final hiveItems = _safeRead(
      (box) =>
          box.values.where((item) => item.retryCount >= _maxRetries).toList(),
      <ApiQueueItem>[],
    );
    final memoryItems =
        _memoryQueue.where((item) => item.retryCount >= _maxRetries).toList();
    return [...hiveItems, ...memoryItems];
  }

  /// Get a snapshot of accumulated offline pings without clearing.
  /// Used for periodic auto-saves to persist data without losing the in-memory accumulator.
  List<Map<String, dynamic>> getOfflinePingsSnapshot() {
    return List<Map<String, dynamic>>.from(_offlinePings);
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

  /// Drop every queued item whose wire tag can no longer be validated.
  ///
  /// A wire tag only re-derives under the session that minted it: the server
  /// recomputes it from the session_id the batch is POSTed under and skips the
  /// entry entirely on a mismatch, while still returning success, so the app
  /// prunes the item as uploaded and the TX ping is lost with no error
  /// anywhere (`wardrive-api.php`, action=wire_tag_mismatch).
  ///
  /// Call this whenever the session id changes underneath a preserved queue.
  /// Every item queued at that moment was necessarily minted under the old
  /// session (anything minted under the new one is enqueued afterwards), so
  /// dropping all tagged items is exact and needs no per-item bookkeeping.
  ///
  /// Auto-reconnect is the path that matters: it deliberately preserves the
  /// queue, and /auth only reuses a session while it is status=1 and
  /// unexpired. Otherwise a fresh session_id comes back and everything
  /// already queued is stale.
  ///
  /// Dropping rather than un-tagging is deliberate. Re-minting under the new
  /// session would claim a tag that never went out on the air. Stripping the
  /// tag sends the ping down the server coords path, where hours (or just a
  /// reconnect) later there is no status-4 WAIT row to join, so it inserts as
  /// DEAD(3) and renders a GREY "dead" cell for a ping that was actually
  /// heard. At roughly 0.2% of TX pings, an honest drop beats a misleading
  /// map.
  Future<void> dropStaleTaggedItems() async {
    final staleHive = _safeRead(
      (box) => box.values.where((i) => i.hasWireTag).toList(),
      <ApiQueueItem>[],
    );
    for (final item in staleHive) {
      try {
        await item.delete();
      } catch (e) {
        debugError('[API QUEUE] Failed to drop stale tagged item: $e');
      }
    }

    final beforeMemory = _memoryQueue.length;
    _memoryQueue.removeWhere((i) => i.hasWireTag);
    final dropped = staleHive.length + (beforeMemory - _memoryQueue.length);

    if (dropped > 0) {
      debugWarn(
          '[API QUEUE] Session changed: dropped $dropped queued TX ping(s) whose wire tag '
          'was minted under the old session (undeliverable)');
      onQueueUpdated?.call(queueSize);
    }
  }

  /// Extract all queued items as API JSON without clearing the queue.
  /// Used to preserve data before session-expiry disconnect.
  ///
  /// Tagged TX pings are left OUT of the snapshot. It is bound for offline
  /// storage and gets re-uploaded under a brand new `offline-YYYYMMDD-NNNN`
  /// session, where the tag cannot re-derive: the server would skip the row
  /// while still reporting success, so the ping is lost either way. Preserving
  /// it only buys a wire_tag_mismatch warn. RX/DISC/TRACE carry no tag and are
  /// preserved exactly as before.
  Future<List<Map<String, dynamic>>> extractAllAsJson() async {
    // Flush RX buffer first so all items are in the main queue
    await _flushRxBuffer();

    final hiveItems = _safeRead(
      (box) => box.values.toList(),
      <ApiQueueItem>[],
    );

    final allItems = [...hiveItems, ..._memoryQueue];

    if (allItems.isEmpty) return [];

    final deliverable = allItems.where((i) => !i.hasWireTag).toList();
    final skipped = allItems.length - deliverable.length;
    if (skipped > 0) {
      debugWarn(
          '[API QUEUE] Preserving offline: skipped $skipped tagged TX ping(s) that no '
          'offline session could upload (kept ${deliverable.length} untagged item(s))');
    }

    return deliverable.map((item) => item.toApiJson()).toList();
  }

  /// Dispose of resources
  void dispose() {
    _batchTimer?.cancel();
    _pingFlushTimer?.cancel();
    _box?.close();
  }
}
