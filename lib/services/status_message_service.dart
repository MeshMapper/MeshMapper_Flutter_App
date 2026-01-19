import 'dart:async';

import '../utils/debug_logger_io.dart';

/// Status message colors matching WebClient STATUS_COLORS
enum StatusColor {
  idle('text-slate-300'),
  info('text-sky-300'),
  success('text-emerald-300'),
  warning('text-amber-300'),
  error('text-rose-300');

  final String className;
  const StatusColor(this.className);
}

/// Status message with text and color
class StatusMessage {
  final String text;
  final StatusColor color;
  final DateTime timestamp;

  StatusMessage(this.text, this.color) : timestamp = DateTime.now();

  @override
  String toString() => 'StatusMessage("$text", ${color.name})';
}

/// Dynamic status message service with minimum visibility enforcement
/// Reference: setStatus(), setDynamicStatus() in wardrive.js
///
/// Key features:
/// - Minimum visibility duration (500ms) prevents status flicker
/// - Message queue with automatic timeout
/// - Countdown timer support (bypasses minimum visibility)
/// - Persistent error messages (outside zone, outdated version)
class StatusMessageService {
  /// Minimum time a status message must remain visible (500ms)
  static const Duration minVisibility = Duration(milliseconds: 500);

  /// Current status message
  StatusMessage? _currentMessage;

  /// Timestamp when current message was set
  DateTime? _lastSetTime;

  /// Pending message to display after minimum visibility
  StatusMessage? _pendingMessage;

  /// Timer for pending message
  Timer? _pendingTimer;

  /// Persistent error message (outside zone, outdated app)
  /// Blocks all other dynamic status messages except clearing itself
  String? _persistentError;

  /// Stream controller for status message updates
  final _controller = StreamController<StatusMessage?>.broadcast();

  /// Stream of status message updates
  Stream<StatusMessage?> get stream => _controller.stream;

  /// Current status message
  StatusMessage? get currentMessage => _currentMessage;

  /// Check if persistent error is active
  bool get hasPersistentError => _persistentError != null;

  /// Set status message with minimum visibility enforcement
  /// @param text - Status message text
  /// @param color - Status color
  /// @param immediate - If true, bypass minimum visibility (for countdown timers)
  void setStatus(String text, StatusColor color, {bool immediate = false}) {
    final now = DateTime.now();
    final timeSinceLastSet = _lastSetTime != null
        ? now.difference(_lastSetTime!)
        : const Duration(seconds: 99);

    // Special case: if this is the same message, update timestamp without changing UI
    // This prevents countdown timer updates from being delayed unnecessarily
    // Example: If status is already "Waiting (10s)", the next "Waiting (9s)" won't be delayed
    if (_currentMessage?.text == text && _currentMessage?.color == color) {
      debugLog('[STATUS] Status update (same message): "$text"');
      _lastSetTime = now;
      return;
    }

    // If immediate flag is set (for countdown timers), apply immediately
    if (immediate) {
      _applyImmediately(text, color);
      return;
    }

    // If minimum visibility time has passed, apply immediately
    if (timeSinceLastSet >= minVisibility) {
      _applyImmediately(text, color);
      return;
    }

    // Minimum visibility time has not passed, queue the message
    final delayNeeded = minVisibility - timeSinceLastSet;
    debugLog('[STATUS] Status queued (${delayNeeded.inMilliseconds}ms delay): "$text" (current: "${_currentMessage?.text}")');

    // Store pending message
    _pendingMessage = StatusMessage(text, color);

    // Clear any existing pending timer
    _pendingTimer?.cancel();

    // Schedule the pending message
    _pendingTimer = Timer(delayNeeded, () {
      if (_pendingMessage != null) {
        final pending = _pendingMessage!;
        _pendingMessage = null;
        _pendingTimer = null;
        _applyImmediately(pending.text, pending.color);
      }
    });
  }

  /// Set dynamic status message (can be blocked by persistent errors)
  /// @param text - Status message text
  /// @param color - Status color
  /// @param immediate - If true, bypass minimum visibility (for countdown updates)
  void setDynamicStatus(String text, StatusColor color, {bool immediate = false}) {
    // If persistent error is active, block all other messages (except clearing it)
    if (_persistentError != null && text != _persistentError) {
      debugLog('[STATUS] Dynamic status blocked by persistent error: "$text"');
      return;
    }

    setStatus(text, color, immediate: immediate);
  }

  /// Set persistent error message that blocks all other dynamic status messages
  /// Used for outside zone errors and outdated app version
  void setPersistentError(String text, StatusColor color) {
    _persistentError = text;
    debugLog('[STATUS] Set persistent error: "$text"');
    setStatus(text, color);
  }

  /// Clear persistent error message
  void clearPersistentError() {
    if (_persistentError != null) {
      debugLog('[STATUS] Clearing persistent error: "$_persistentError"');
      _persistentError = null;
      // Clear to idle status
      setStatus('Ready', StatusColor.idle);
    }
  }

  /// Clear dynamic status message (countdown timers, etc.)
  /// Resets to idle "Ready" state unless a persistent error is active
  void clearDynamicStatus() {
    // Don't clear if persistent error is blocking
    if (_persistentError != null) {
      debugLog('[STATUS] clearDynamicStatus blocked by persistent error');
      return;
    }

    // Cancel any pending message
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _pendingMessage = null;

    // Reset to idle status
    debugLog('[STATUS] Clearing dynamic status');
    _applyImmediately('Ready', StatusColor.idle);
  }

  /// Apply status message immediately (internal)
  void _applyImmediately(String text, StatusColor color) {
    _currentMessage = StatusMessage(text, color);
    _lastSetTime = DateTime.now();
    _controller.add(_currentMessage);
    debugLog('[STATUS] Status applied: "$text"');
  }

  /// Dispose of resources
  void dispose() {
    _pendingTimer?.cancel();
    _pendingTimer = null;
    _controller.close();
  }
}
