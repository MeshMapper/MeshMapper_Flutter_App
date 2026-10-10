import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive/hive.dart';

import '../models/api_queue_item.dart';
import '../utils/debug_logger_io.dart';
import '../utils/public_key.dart';
import 'api_service.dart';
import 'custom_api_service.dart';
import 'network_state_service.dart';

/// Extracts the public key a DISC item reports, or null when the item is
/// not a successful DISC (a failed discovery's heardRepeats is `'None'`, and
/// nothing else carries this shape). Used to line a SCOPES item up with the
/// DISC that must precede it.
String? _discKeyOf(ApiQueueItem item) {
  if (item.type != 'DISC' || item.heardRepeats == 'None') return null;
  // "repeaterId:nodeType:localSnr:localRssi:remoteSnr:pubkeyFull"
  final parts = item.heardRepeats.split(':');
  if (parts.length < 6 || parts[5].isEmpty) return null;
  return parts[5].toUpperCase();
}

/// Selects which eligible items belong in the next batch, holding a SCOPES
/// item back until its DISC has either already left in an earlier batch (no
/// longer anywhere in the queue) or rides along in this same batch.
///
/// The server records every DISC-heard key of a batch before it checks any
/// SCOPES in it, but refuses a SCOPES whose DISC only arrives LATER, so a
/// SCOPES item must never be uploaded ahead of the DISC it depends on.
///
/// [eligible] is every item ready for this batch, in the existing order
/// (retry eligibility, Hive before memory). [allQueued] is every item
/// currently held, Hive and memory alike, regardless of retry eligibility:
/// a DISC sitting in retry backoff still counts as "not yet delivered", so
/// its SCOPES must wait for it even though the DISC itself is not eligible
/// for this batch.
///
/// Non-SCOPES items are selected first, up to [batchSize], so a run of
/// blocked SCOPES at the head of the queue can never crowd out the DISC
/// items behind them; a held-back SCOPES never occupies a slot.
List<ApiQueueItem> selectBatchWithScopesDependency({
  required List<ApiQueueItem> eligible,
  required List<ApiQueueItem> allQueued,
  required int batchSize,
}) {
  final discKeysAnywhere = <String>{};
  for (final item in allQueued) {
    final key = _discKeyOf(item);
    if (key != null) discKeysAnywhere.add(key);
  }

  final nonScopes = <ApiQueueItem>[];
  final scopesCandidates = <ApiQueueItem>[];
  for (final item in eligible) {
    if (item.type == 'SCOPES') {
      scopesCandidates.add(item);
    } else {
      nonScopes.add(item);
    }
  }

  final selected = nonScopes.take(batchSize).toList();

  final selectedDiscKeys = <String>{};
  for (final item in selected) {
    final key = _discKeyOf(item);
    if (key != null) selectedDiscKeys.add(key);
  }

  var remaining = batchSize - selected.length;
  if (remaining > 0) {
    for (final scopeItem in scopesCandidates) {
      if (remaining <= 0) break;
      final key = scopeItem.heardRepeats.toUpperCase();
      final discAlreadyDelivered = !discKeysAnywhere.contains(key);
      if (selectedDiscKeys.contains(key) || discAlreadyDelivered) {
        selected.add(scopeItem);
        remaining--;
      }
    }
  }

  return selected;
}

/// Stable-partitions API JSON rows so every SCOPES row comes after every
/// other row, preserving relative order within each group. The server
/// records a batch or offline chunk's DISC-heard keys before it checks any
/// SCOPES in it, but refuses a SCOPES whose DISC only arrives in a LATER
/// batch or chunk, so every export and every chunk boundary must keep DISC
/// (and everything else) ahead of SCOPES, whatever order the rows were
/// recorded or stored in.
List<Map<String, dynamic>> orderDiscBeforeScopes(
    List<Map<String, dynamic>> rows) {
  final others = rows.where((r) => r['type'] != 'SCOPES').toList();
  final scopes = rows.where((r) => r['type'] == 'SCOPES').toList();
  return [...others, ...scopes];
}

/// The two altitude references the app ever labels.
const Set<String> kAltitudeReferences = {'msl', 'ellipsoid'};

/// One short phrase per upload saying how many rows carried a labelled
/// altitude, by type, for the Android 14 device check. Batch level only,
/// never per fix. Example: `altitude_ref 3/5 (TX 2/3, RX 1/2)`.
String altitudeLabelSummary(List<Map<String, dynamic>> entries) {
  final byType = <String, (int labelled, int total)>{};
  var labelled = 0;
  var total = 0;
  for (final e in entries) {
    final type = e['type']?.toString() ?? '?';
    if (type == 'DEFER' || type == 'SCOPES') continue;
    final has = kAltitudeReferences.contains(e['altitude_ref']);
    total++;
    if (has) labelled++;
    final prev = byType[type] ?? (0, 0);
    byType[type] = (prev.$1 + (has ? 1 : 0), prev.$2 + 1);
  }
  if (total == 0) return 'altitude_ref 0/0';
  final parts = byType.entries
      .map((kv) => '${kv.key} ${kv.value.$1}/${kv.value.$2}')
      .join(', ');
  return 'altitude_ref $labelled/$total ($parts)';
}

/// Removes every SCOPES row from a list of API JSON rows, preserving the
/// order of everything else. Used before an offline upload when the auth
/// answer did not offer scope discovery: the server would refuse every one
/// of them, so they are stripped before the partial-upload cleanup counts
/// rows by how many were actually uploaded.
List<Map<String, dynamic>> withoutScopesItems(
    List<Map<String, dynamic>> rows) {
  return rows.where((r) => r['type'] != 'SCOPES').toList();
}

/// Result of [runOfflineChunkedUpload].
class OfflineChunkedUploadResult {
  /// The rows actually offered for upload, after the SCOPES strip and the
  /// DISC-before-SCOPES reorder. This is also what was handed to
  /// `persistRows` whenever the original rows held any SCOPES row, so it is
  /// what the caller's prefix-by-uploaded-count cleanup must read against.
  final List<Map<String, dynamic>> orderedRows;

  /// How many of [orderedRows], counting from the start, were successfully
  /// uploaded before the first chunk that was not.
  final int uploadedCount;

  /// How many SCOPES rows were stripped because the upload auth did not
  /// offer scope discovery (0 when it did).
  final int removedScopesCount;

  const OfflineChunkedUploadResult({
    required this.orderedRows,
    required this.uploadedCount,
    required this.removedScopesCount,
  });
}

/// Orchestrates an offline session's chunked upload, kept free of network
/// and storage specifics so it is testable without an `AppStateProvider`.
///
/// Strips every SCOPES row when [scopeDiscoveryOffered] is false, then moves
/// every remaining SCOPES row after every other row (DISC before SCOPES, a
/// stable partition, [orderDiscBeforeScopes]). When [rows] held ANY SCOPES
/// row, the resulting order is handed to [persistRows] BEFORE the first
/// chunk is built: the caller's partial-upload cleanup later removes a
/// PREFIX of the stored rows by uploaded count, and that prefix only lines
/// up with what was actually sent when the stored file holds the same order
/// that was chunked. A session with no SCOPES rows at all skips the write
/// (the stored order already matches, since stripping and reordering are
/// both no-ops with nothing to strip or reorder).
///
/// [uploadChunk] is called once per fixed-size chunk, in order, with the
/// chunk's rows, its 1-based number and the total chunk count; it must
/// perform whatever retry the caller wants and return true only on an
/// eventual success. The loop stops at the first chunk that returns false,
/// so every row from that chunk on is left un-uploaded.
///
/// This function, not [uploadChunk], decides what reaches the custom API:
/// [forwardChunk] is called once for each chunk that uploaded, right after
/// it did, with exactly that chunk's rows. A chunk that failed and every
/// chunk after it are never forwarded, and no chunk is forwarded twice.
Future<OfflineChunkedUploadResult> runOfflineChunkedUpload(
  List<Map<String, dynamic>> rows, {
  required bool scopeDiscoveryOffered,
  required int batchSize,
  required Future<void> Function(List<Map<String, dynamic>> orderedRows)
      persistRows,
  required Future<bool> Function(
    List<Map<String, dynamic>> chunk,
    int chunkNumber,
    int totalChunks,
  ) uploadChunk,
  required void Function(List<Map<String, dynamic>> chunk, int chunkNumber)
      forwardChunk,
}) async {
  final stripped = scopeDiscoveryOffered ? rows : withoutScopesItems(rows);
  final removedScopesCount = rows.length - stripped.length;
  final ordered = orderDiscBeforeScopes(stripped);

  if (rows.any((r) => r['type'] == 'SCOPES')) {
    await persistRows(ordered);
  }

  final totalChunks =
      ordered.isEmpty ? 0 : (ordered.length + batchSize - 1) ~/ batchSize;
  var uploadedCount = 0;
  for (var i = 0; i < ordered.length; i += batchSize) {
    final chunkNumber = (i ~/ batchSize) + 1;
    final chunk = ordered.skip(i).take(batchSize).toList();
    final ok = await uploadChunk(chunk, chunkNumber, totalChunks);
    if (!ok) break;
    uploadedCount += chunk.length;
    forwardChunk(chunk, chunkNumber);
  }

  return OfflineChunkedUploadResult(
    orderedRows: ordered,
    uploadedCount: uploadedCount,
    removedScopesCount: removedScopesCount,
  );
}

/// API queue service with batch upload and retry logic
/// Ported from apiQueue and batchUpload() in wardrive.js
///
/// Features:
/// - Queue pings locally with Hive persistence
/// - Upload batches contain up to 50 entries and use network-aware timers
/// - RX buffering: group by repeater ID (max 4 per batch)
/// - Retry with exponential backoff for failed uploads
/// - Offline mode: accumulates pings without uploading
class ApiQueueService {
  static const String _boxName = 'api_queue';
  static const int _batchSize = 50;
  static const Duration _batchTimeout = Duration(seconds: 15);
  // Wider cadence while on a constrained (e.g. satellite) link: fewer, larger
  // batches beat frequent small ones when every round trip carries high
  // per-request latency.
  static const Duration _batchTimeoutConstrained = Duration(seconds: 60);
  static const Duration _pingFlushTimeout = Duration(seconds: 5);
  static const Duration _pingFlushTimeoutConstrained = Duration(seconds: 60);
  static const int _maxRetries = 5;
  static const int _maxRxPerRepeater = 4;

  final ApiService _apiService;
  final NetworkStateSource _networkState;
  Box<ApiQueueItem>? _box;
  Timer? _batchTimer;
  Timer? _pingFlushTimer;
  StreamSubscription<NetworkState>? _networkStateSubscription;
  late bool _lastIsConstrained;
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

  /// Bumped every time the queue is cleared ([clear], [clearBeforeConnect],
  /// [clearOnDisconnect], and the stale-item sweep in [init]). A scope
  /// discovery answer's send and its enqueue are separated by a mesh round
  /// trip, so the queue can be cleared out from under a call that is still
  /// in flight; the caller reads this before starting and passes it back so
  /// a late insertion can tell whether the queue it was aimed at still
  /// exists.
  int _generation = 0;

  /// The current queue generation. Read before a scope answer's send, then
  /// passed back to [enqueueScopes] as `expectedGeneration`.
  int get generation => _generation;

  /// Bumps [generation]. Called FIRST by every clear path, before the clear
  /// itself, so a write already in flight against the old generation sees
  /// the new one before (or regardless of whether) the clear it raced
  /// finishes, and cannot resurrect a stale item into a queue that is being
  /// or has just been emptied.
  void _bumpGeneration() => _generation++;

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

  /// The auto mode running right now, as the server's enum, or null when
  /// nothing is wired. Read by every enqueue when it builds its item, so one
  /// wire covers every producer (PingService, RxLogger) with the callers
  /// untouched. An item is stamped when its enqueue is called. For RX that is
  /// when RxLogger hands the row over (up to 30 s or 25 m after the packet was
  /// heard), not when the queue's own buffer flushes.
  String Function()? autoModeGetter;

  /// The live radio's configuration tag (`freqMHz,bwKHz,SF,CR`) or null,
  /// read at every enqueue the same way [autoModeGetter] is. Live only: the
  /// stamp says what the radio was running when the item was recorded, so
  /// the provider wires the connection's SelfInfo here, never a remembered
  /// value.
  String? Function()? radioConfigGetter;

  /// Whether the region has offered scope discovery, wired to
  /// `ApiService.scopeDiscoveryOffered`. Null (not wired) is read as
  /// allowed; the batch builder drops every queued SCOPES item the moment
  /// this returns `false`, whatever the queue holds.
  bool Function()? scopesAllowedGetter;

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

  ApiQueueService({
    required ApiService apiService,
    NetworkStateSource? networkState,
  })  : _apiService = apiService,
        _networkState = networkState ?? NetworkStateService.instance {
    _lastIsConstrained = _networkState.current.isConstrained;
    _networkStateSubscription =
        _networkState.stream.listen(_handleNetworkState);
  }

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
    _bumpGeneration();
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

  /// Opens the fresh box [_recoverBox] switches to after deleting the
  /// corrupt one. Production always opens the real queue box; a test swaps
  /// this to control what the recovered box does with the retried write.
  @visibleForTesting
  Future<Box<ApiQueueItem>> Function() reopenBoxForRecovery =
      () => Hive.openBox<ApiQueueItem>(_boxName);

  /// Recover from runtime Hive corruption by closing, deleting, and reopening the box
  Future<void> _recoverBox() async {
    if (_isRecovering) {
      debugLog('[API QUEUE] Recovery already in progress, skipping');
      return;
    }
    _isRecovering = true;

    // Deleting the box erases every queued item, exactly as a clear does, so
    // it is a new generation. Bumped synchronously, before the first await
    // below, like the clear paths: a SCOPES whose DISC sat in this box would
    // otherwise be accepted by its retry and uploaded as if the DISC had gone
    // out. That includes a second enqueue that fails while this recovery is
    // still closing the box: it skips recovery (one runs at a time) and must
    // already see the new generation, or it lands in memory under the old one.
    _bumpGeneration();
    debugLog('[API QUEUE] Queue generation bumped for storage recovery');

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

      final box =
          await reopenBoxForRecovery().timeout(const Duration(seconds: 5));
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
    String? altitudeRef,
    double? altitudeAccuracy,
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
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoModeGetter?.call(),
      radioFreq: radioConfigGetter?.call(),
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
    _schedulePingFlush();
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
    String? altitudeRef,
    double? altitudeAccuracy,
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
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoModeGetter?.call(),
      radioFreq: radioConfigGetter?.call(),
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
    String? altitudeRef,
    double? altitudeAccuracy,
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
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoModeGetter?.call(),
      radioFreq: radioConfigGetter?.call(),
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
    _schedulePingFlush();
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
    String? altitudeRef,
    double? altitudeAccuracy,
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
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoModeGetter?.call(),
      radioFreq: radioConfigGetter?.call(),
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
    _schedulePingFlush();
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
    String? altitudeRef,
    double? altitudeAccuracy,
  }) async {
    final item = ApiQueueItem.fromDiscDrop(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      externalAntenna: externalAntenna,
      noiseFloor: noiseFloor,
      power: power,
      altitude: altitude,
      altitudeRef: altitudeRef,
      altitudeAccuracy: altitudeAccuracy,
      autoMode: autoModeGetter?.call(),
      radioFreq: radioConfigGetter?.call(),
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
    _schedulePingFlush();
  }

  /// Report a square where smart pinging held a ping. [held] is `tx` or
  /// `disc`. The server verifies the square against its own coverage and
  /// credits it once per session; a dropped one is silent. Modelled on
  /// enqueueDiscDrop: offline rows honour the airborne pause, a closed box
  /// falls back to memory, and the network-aware flush timer sends it on.
  Future<void> enqueueDefer({
    required double latitude,
    required double longitude,
    required int timestamp,
    required String held,
  }) async {
    final item = ApiQueueItem.fromDefer(
      latitude: latitude,
      longitude: longitude,
      timestamp: timestamp,
      held: held,
      radioFreq: radioConfigGetter?.call(),
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      if (_dropOfflineRowIfPaused()) return;
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] DEFER ($held) enqueued (offline)');
      return;
    }

    final wrote = await _safeWrite((box) => box.add(item));
    if (!wrote) {
      _memoryQueue.add(item);
      debugLog(
          '[API QUEUE] DEFER ($held) enqueued (memory fallback) at $latitude, $longitude (queue size: $queueSize)');
    } else {
      debugLog(
          '[API QUEUE] DEFER ($held) enqueued at $latitude, $longitude (queue size: $queueSize)');
    }
    onQueueUpdated?.call(queueSize);
    _schedulePingFlush();
  }

  /// Queue a repeater's scope discovery answer. The public key rides in the
  /// heardRepeats slot, the DISC/DEFER packing precedent, with the answer
  /// itself in [ApiQueueItem.scopes]. Modelled on [enqueueDefer]: offline
  /// rows honour the airborne pause, a closed box falls back to memory, and
  /// the network-aware flush timer sends it on.
  ///
  /// A scope answer's send and its enqueue are separated by a mesh round
  /// trip, during which a disconnect can clear the queue out from under it.
  /// [expectedGeneration] (read from [generation] before the send started)
  /// is checked immediately before every write attempt this call makes,
  /// including a Hive recovery retry and the memory-fallback insertion. A
  /// mismatch at any of those points returns false and leaves nothing
  /// inserted, undoing a write that already landed rather than resurrecting
  /// an item into a queue that no longer exists.
  Future<bool> enqueueScopes({
    required String publicKeyHex,
    required List<String> scopes,
    required double lat,
    required double lon,
    required int timestamp,
    required int expectedGeneration,
    String? radioFreq,
  }) async {
    if (!lat.isFinite || !lon.isFinite) {
      debugWarn('[API QUEUE] SCOPES dropped: non-finite lat/lon');
      return false;
    }

    // The server rejects the whole item unless this is exactly 64
    // upper-case hex; refuse here rather than upload something it will
    // discard silently.
    final normalizedKey = normalizePublicKey(publicKeyHex);
    if (normalizedKey == null) {
      debugWarn('[API QUEUE] SCOPES dropped: invalid public key');
      return false;
    }

    final item = ApiQueueItem.fromScopes(
      publicKeyHex: normalizedKey,
      scopes: scopes,
      lat: lat,
      lon: lon,
      timestamp: timestamp,
      radioFreq: radioFreq ?? radioConfigGetter?.call(),
    );

    // In offline mode, accumulate to offline pings list instead of queue
    if (offlineMode) {
      if (_dropOfflineRowIfPaused()) return false;
      if (expectedGeneration != _generation) {
        debugWarn(
            '[API QUEUE] SCOPES dropped: queue generation changed (queue was cleared)');
        return false;
      }
      _offlinePings.add(item.toApiJson());
      debugLog('[API QUEUE] SCOPES enqueued (offline)');
      return true;
    }

    if (expectedGeneration != _generation) {
      debugWarn(
          '[API QUEUE] SCOPES dropped: queue generation changed before write (queue was cleared)');
      return false;
    }

    final box = _box;
    var wrote = false;
    if (box != null) {
      try {
        await box.add(item);
        wrote = true;
      } catch (e) {
        debugError(
            '[API QUEUE] SCOPES write failed: $e - attempting recovery');
        await _recoverBox();
        if (expectedGeneration != _generation) {
          debugWarn(
              '[API QUEUE] SCOPES dropped: queue generation changed during recovery (queue was cleared)');
          return false;
        }
        final retryBox = _box;
        if (retryBox != null) {
          try {
            await retryBox.add(item);
            wrote = true;
          } catch (e2) {
            debugError('[API QUEUE] SCOPES write failed after recovery: $e2');
          }
        }
      }
    }

    if (wrote) {
      if (expectedGeneration != _generation) {
        // The clear that bumped the generation may have run while the write
        // above (or its retry) was in flight. What landed belongs to a queue
        // that no longer exists, so undo it rather than leave it queued.
        try {
          await item.delete();
        } catch (_) {}
        debugWarn(
            '[API QUEUE] SCOPES dropped: queue generation changed during write (queue was cleared)');
        return false;
      }
      debugLog('[API QUEUE] SCOPES enqueued (queue size: $queueSize)');
    } else {
      // Every Hive attempt failed. A clear may have landed while the last
      // of them was failing, so check again before the memory fallback.
      if (expectedGeneration != _generation) {
        debugWarn(
            '[API QUEUE] SCOPES dropped: queue generation changed before memory fallback (queue was cleared)');
        return false;
      }
      _memoryQueue.add(item);
      debugLog(
          '[API QUEUE] SCOPES enqueued (memory fallback) (queue size: $queueSize)');
    }
    onQueueUpdated?.call(queueSize);
    _schedulePingFlush();
    return true;
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

  void _handleNetworkState(NetworkState state) {
    if (state.isConstrained == _lastIsConstrained) return;

    _lastIsConstrained = state.isConstrained;
    debugLog('[API QUEUE] Network pacing changed: '
        '${state.isConstrained ? 'constrained' : 'ordinary'}');

    if (_batchTimer != null) _startBatchTimer();
    if (_pingFlushTimer?.isActive ?? false) _schedulePingFlush();
  }

  void _schedulePingFlush() {
    final timeout =
        _lastIsConstrained ? _pingFlushTimeoutConstrained : _pingFlushTimeout;
    _pingFlushTimer?.cancel();
    _pingFlushTimer = Timer(timeout, () {
      debugLog('[API QUEUE] Ping flush timer fired '
          '(${timeout.inSeconds}s delay'
          '${_lastIsConstrained ? ', constrained network' : ''}), '
          '$queueSize queued');
      _flushRxBuffer();
      _uploadBatch(silentWhenEmpty: true);
    });
  }

  void _startBatchTimer() {
    final constrained = _lastIsConstrained;
    final timeout = constrained ? _batchTimeoutConstrained : _batchTimeout;
    _batchTimer?.cancel();
    _batchTimer = Timer.periodic(timeout, (_) {
      // The tick carries the queue depth, so an idle lane is one line instead
      // of this plus an "Upload skipped: queue empty" underneath it. The tick
      // itself stays: its cadence is what shows the lane going quiet.
      debugLog('[API QUEUE] Batch timer fired (${timeout.inSeconds}s interval'
          '${constrained ? ', constrained network' : ''}), '
          '$queueSize queued');
      _flushRxBuffer();
      _uploadBatch(silentWhenEmpty: true);
    });
  }

  /// Manually flush queue (called by TX-triggered flush timer)
  Future<void> flushQueue() async {
    await _flushRxBuffer();
    await _uploadBatch();
  }

  /// Removes every queued SCOPES item when the region has not offered scope
  /// discovery (the key was absent from the live /auth answer). Called at
  /// the top of every upload attempt so a queue built before the app learned
  /// this never tries to send rows the server will refuse.
  Future<void> _dropDisallowedScopesItems() async {
    if (scopesAllowedGetter?.call() != false) return;

    final hiveScopes = _safeRead(
      (box) => box.values.where((i) => i.type == 'SCOPES').toList(),
      <ApiQueueItem>[],
    );
    for (final item in hiveScopes) {
      try {
        await item.delete();
      } catch (e) {
        debugError('[API QUEUE] Failed to drop disallowed SCOPES item: $e');
      }
    }

    final beforeMemory = _memoryQueue.length;
    _memoryQueue.removeWhere((i) => i.type == 'SCOPES');
    final dropped = hiveScopes.length + (beforeMemory - _memoryQueue.length);

    if (dropped > 0) {
      debugWarn(
          '[API QUEUE] Dropped $dropped SCOPES item(s): scope discovery not offered');
      onQueueUpdated?.call(queueSize);
    }
  }

  /// Upload batch of queued items (from Hive box or in-memory fallback)
  ///
  /// [silentWhenEmpty] suppresses the empty-queue line for callers that
  /// already report the depth themselves (the periodic timers). Every other
  /// caller keeps it: on the disconnect flush, "queue empty" is the line that
  /// distinguishes a drained queue from an upload that never ran.
  Future<void> _uploadBatch({bool silentWhenEmpty = false}) async {
    if (_isUploading) {
      debugLog('[API QUEUE] Upload skipped: already uploading');
      return;
    }
    // Claim the guard BEFORE any await below (including the scope-removal
    // pass): two overlapping flushes (the batch timer and the ping flush
    // timer can fire close together) both read `_isUploading` in the same
    // event-loop turn if it is set any later, both pass the check, and both
    // select and upload the same items. Released in `finally` so every
    // return path below (including the early ones) clears it.
    _isUploading = true;

    try {
      await _dropDisallowedScopesItems();

      final hiveEmpty = _safeRead((box) => box.isEmpty, true);
      final memoryEmpty = _memoryQueue.isEmpty;

      if (hiveEmpty && memoryEmpty) {
        if (!silentWhenEmpty) {
          debugLog('[API QUEUE] Upload skipped: queue empty');
        }
        return;
      }

      // Collect every eligible item from both Hive and memory queue, in the
      // existing order (Hive before memory), uncapped: the SCOPES dependency
      // filter below decides what fills the batch, not this read, or a run
      // of blocked SCOPES at the head of the queue could crowd out the
      // non-SCOPES items behind them.
      final eligibleHive = _safeRead(
          (box) => box.values
              .where((item) =>
                  item.retryCount < _maxRetries &&
                  item.isReadyForRetry &&
                  item.isUploadEligible)
              .toList(),
          <ApiQueueItem>[]);

      final eligibleMemory = _memoryQueue
          .where((item) =>
              item.retryCount < _maxRetries &&
              item.isReadyForRetry &&
              item.isUploadEligible)
          .toList();

      // Every item currently held, regardless of retry eligibility: a DISC
      // still climbing the retry ladder has not been delivered, so its
      // SCOPES must wait for it even though the DISC itself is not eligible
      // for this batch.
      final allQueued = [
        ..._safeRead((box) => box.values.toList(), <ApiQueueItem>[]),
        ..._memoryQueue,
      ];

      // Excluded here independently of whether `_dropDisallowedScopesItems`
      // above actually managed to delete anything: a Hive deletion failure
      // (logged there) must not let a disallowed SCOPES item back into the
      // batch, or the custom-API forward that rides the same `pings` list.
      final scopesBlocked = scopesAllowedGetter?.call() == false;
      final eligible = scopesBlocked
          ? [...eligibleHive, ...eligibleMemory]
              .where((item) => item.type != 'SCOPES')
              .toList()
          : [...eligibleHive, ...eligibleMemory];

      final items = selectBatchWithScopesDependency(
        eligible: eligible,
        allQueued: allQueued,
        batchSize: _batchSize,
      );

      if (items.isEmpty) {
        debugLog('[API QUEUE] Upload skipped: no items ready for upload');
        return;
      }

      final hiveItems = items.where((item) => item.isInBox).toList();
      final memoryItems = items.where((item) => !item.isInBox).toList();

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
        // A replay that left SCOPES out (scope discovery withdrawn while the
        // first attempt failed) still deletes them below, since the region
        // no longer takes them, but they were never sent, so they are not
        // counted as uploaded, handed on, or forwarded.
        final strippedScopes = _apiService.lastUploadDroppedScopes > 0;
        final sentItems = strippedScopes
            ? items.where((item) => item.type != 'SCOPES').toList()
            : items;
        final uploadedCount = sentItems.length;
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
        debugLog('[API QUEUE] Upload SUCCESS: deleted ${items.length} items'
            '${strippedScopes ? ' ($uploadedCount sent, ${items.length - uploadedCount} SCOPES dropped by the replay)' : ''}');
        // The network is demonstrably back, so give anything the ladder has
        // already written off one more chance.
        _reviveFailedItems();
        onUploadSuccess?.call(uploadedCount, sentItems);
        // Fire-and-forget: forward to custom API endpoint. A withdrawal
        // that landed while this batch was in flight made the replay leave
        // its SCOPES out (ApiService.submitWardriveData), so leave them out
        // here too: a withdrawn answer is never forwarded.
        customApiService?.forwardPings(
            strippedScopes || scopesAllowedGetter?.call() == false
                ? withoutScopesItems(pings)
                : pings);
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
    _bumpGeneration();
    await _safeWrite((box) => box.clear());
    _memoryQueue.clear();
    _rxBuffer.clear();
    onQueueUpdated?.call(0);
  }

  /// Clear queue on disconnect - ALWAYS START FRESH
  /// Called when device disconnects to ensure no stale pings remain
  /// Also stops the batch timer to prevent upload attempts without a session
  Future<void> clearOnDisconnect() async {
    _bumpGeneration();

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
    _bumpGeneration();
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

  /// Direct access to the underlying Hive box.
  ///
  /// Exists so a test can force the "box unavailable" path for exactly one
  /// write (set to null, enqueue, then restore) without going through the
  /// real recovery flow, which deletes the box from disk and would destroy
  /// items a test already committed to it. Production code never reads or
  /// writes this; it always goes through [_box].
  @visibleForTesting
  Box<ApiQueueItem>? get testBox => _box;
  @visibleForTesting
  set testBox(Box<ApiQueueItem>? box) => _box = box;

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

    // Hive-then-memory concatenation order says nothing about which item's
    // DISC counterpart went out first, so every SCOPES row is moved after
    // every other row here (a stable partition): the server records a
    // batch's DISC-heard keys before it checks any SCOPES in it, and this
    // snapshot becomes a fresh offline session that re-uploads in chunks.
    return orderDiscBeforeScopes(
        deliverable.map((item) => item.toApiJson()).toList());
  }

  /// Dispose of resources
  void dispose() {
    _batchTimer?.cancel();
    _pingFlushTimer?.cancel();
    _networkStateSubscription?.cancel();
    _box?.close();
  }
}
