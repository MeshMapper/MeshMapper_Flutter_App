import 'dart:async';

import 'package:just_audio/just_audio.dart';
import 'package:hive/hive.dart';
import 'package:audio_session/audio_session.dart';

import '../utils/debug_logger_io.dart';

/// Audio service for playing sound notifications
/// Plays sounds when TX pings are sent and RX packets are received
class AudioService {
  static const String _prefsBoxName = 'audio_preferences';
  static const String _enabledKey = 'sound_enabled';
  static const String _txEnabledKey = 'tx_sound_enabled';
  static const String _rxEnabledKey = 'rx_sound_enabled';
  static const String _txAsset = 'assets/transmitted_packet.mp3';
  static const String _rxAsset = 'assets/received_packet.mp3';

  /// Delay before releasing audio focus after the last sound plays.
  /// Prevents rapid activate/deactivate cycles that break Android audio,
  /// while still releasing focus for Android Auto ducking.
  static const Duration _focusReleaseDelay = Duration(seconds: 3);

  AudioPlayer? _txPlayer;
  AudioPlayer? _rxPlayer;
  bool _initialized = false;
  bool _enabled = false; // Disabled by default, remembered once user changes it
  bool _txEnabled = true; // TX sound sub-toggle (only matters when master is on)
  bool _rxEnabled = true; // RX sound sub-toggle (only matters when master is on)
  Timer? _focusReleaseTimer;

  /// Whether the audio service is initialized
  bool get isInitialized => _initialized;

  /// Whether sound notifications are enabled
  bool get isEnabled => _enabled;

  /// Whether TX sound is enabled (ping sent / discovery sent)
  bool get isTxEnabled => _txEnabled;

  /// Whether RX sound is enabled (repeater echo / RX observation)
  bool get isRxEnabled => _rxEnabled;

  /// Initialize the audio service and pre-load sounds
  Future<void> initialize() async {
    if (_initialized) return;

    try {
      debugLog('[AUDIO] Initializing audio service');

      // Load enabled state from preferences
      await _loadEnabledState();

      // Configure audio session for notification mixing (play over music)
      try {
        final session = await AudioSession.instance;
        await session.configure(
          const AudioSessionConfiguration(
            // iOS: ambient category plays alongside other audio
            avAudioSessionCategory: AVAudioSessionCategory.ambient,
            avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
            avAudioSessionMode: AVAudioSessionMode.defaultMode,
            avAudioSessionRouteSharingPolicy:
                AVAudioSessionRouteSharingPolicy.defaultPolicy,
            avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
            // Android: transient focus allows other audio to continue
            androidAudioAttributes: AndroidAudioAttributes(
              contentType: AndroidAudioContentType.sonification,
              usage: AndroidAudioUsage.notification,
            ),
            androidAudioFocusGainType:
                AndroidAudioFocusGainType.gainTransientMayDuck,
            androidWillPauseWhenDucked: false,
          ),
        );
        debugLog('[AUDIO] Audio session configured for notification mixing');
      } catch (e) {
        debugError('[AUDIO] Failed to configure audio session: $e');
        // Continue initialization - audio will still work, just may interrupt music
      }

      // Create audio players
      _txPlayer = AudioPlayer();
      _rxPlayer = AudioPlayer();

      // Pre-load the audio assets for instant playback
      await _txPlayer!.setAsset(_txAsset);
      await _rxPlayer!.setAsset(_rxAsset);

      _initialized = true;
      debugLog('[AUDIO] Audio service initialized, enabled=$_enabled');
    } catch (e) {
      debugError('[AUDIO] Failed to initialize audio service: $e');
      // Don't throw - audio is not critical functionality
      _initialized = false;
    }
  }

  /// Load enabled state from Hive storage
  Future<void> _loadEnabledState() async {
    final box = await _openBoxSafely(_prefsBoxName);
    if (box == null) return;

    try {
      final enabled = box.get(_enabledKey);
      if (enabled != null) {
        _enabled = enabled as bool;
        debugLog('[AUDIO] Loaded enabled state: $_enabled');
      } else {
        debugLog('[AUDIO] No saved preference, using default: $_enabled');
      }

      final txEnabled = box.get(_txEnabledKey);
      if (txEnabled != null) _txEnabled = txEnabled as bool;
      final rxEnabled = box.get(_rxEnabledKey);
      if (rxEnabled != null) _rxEnabled = rxEnabled as bool;
      debugLog('[AUDIO] Loaded sub-toggles: tx=$_txEnabled, rx=$_rxEnabled');
    } catch (e) {
      debugError('[AUDIO] Failed to load enabled state: $e');
      // Keep defaults
    }
  }

  /// Save enabled state to Hive storage
  Future<void> _saveEnabledState() async {
    final box = await _openBoxSafely(_prefsBoxName);
    if (box == null) return;

    try {
      await box.put(_enabledKey, _enabled);
      debugLog('[AUDIO] Saved enabled state: $_enabled');
    } catch (e) {
      debugError('[AUDIO] Failed to save enabled state: $e');
    }
  }

  /// Open Hive box with timeout and automatic recovery from corruption
  Future<Box<dynamic>?> _openBoxSafely(String boxName) async {
    const timeout = Duration(seconds: 5);

    debugLog('[AUDIO] Opening Hive box "$boxName"...');

    try {
      final box = await Hive.openBox(boxName).timeout(timeout);
      debugLog('[AUDIO] Hive box "$boxName" opened successfully');
      return box;
    } on TimeoutException {
      debugError('[AUDIO] Hive box "$boxName" timed out - attempting recovery');
      return _attemptRecovery(boxName, timeout);
    } catch (e) {
      debugError('[AUDIO] Hive box "$boxName" failed: $e - attempting recovery');
      return _attemptRecovery(boxName, timeout);
    }
  }

  /// Attempt to recover from Hive corruption
  Future<Box<dynamic>?> _attemptRecovery(String boxName, Duration timeout) async {
    try {
      debugLog('[AUDIO] Deleting corrupted box "$boxName"...');
      await Hive.deleteBoxFromDisk(boxName);
      debugLog('[AUDIO] Retrying open...');
      final box = await Hive.openBox(boxName).timeout(timeout);
      debugLog('[AUDIO] Box "$boxName" opened after recovery');
      return box;
    } catch (e) {
      debugError('[AUDIO] Recovery failed for "$boxName": $e - operating without persistence');
      return null;
    }
  }

  /// Play the transmit sound (when TX ping or Discovery request is sent)
  Future<void> playTransmitSound() async {
    if (!_txEnabled) return;
    await _playSound(_txPlayer, _txAsset, 'TX');
  }

  /// Play the receive sound (when repeater echo or RX observation is detected)
  Future<void> playReceiveSound() async {
    if (!_rxEnabled) return;
    await _playSound(_rxPlayer, _rxAsset, 'RX');
  }

  /// Shared playback logic for both TX and RX sounds.
  /// Ensures audio session is active before playing and debounces focus release.
  Future<void> _playSound(AudioPlayer? player, String assetPath, String label) async {
    if (!_initialized || !_enabled || player == null) return;

    try {
      await _ensureSessionActive();
      await player.seek(Duration.zero);
      await player.play().timeout(const Duration(seconds: 3));
      debugLog('[AUDIO] Played $label sound');
      _scheduleFocusRelease();
    } on TimeoutException {
      debugWarn('[AUDIO] $label play() timed out — resetting audio session');
      await player.stop();
      await _resetAudioSession();
    } catch (e) {
      debugError('[AUDIO] Failed to play $label sound: $e');
      // Try to recover the player for next time
      try {
        await player.stop();
        await player.setAsset(assetPath);
        debugLog('[AUDIO] Reloaded $label player after error');
      } catch (reloadError) {
        debugError('[AUDIO] Failed to reload $label player: $reloadError');
      }
    }
  }

  /// Ensure audio session is active before playback.
  /// Cancels any pending focus release to prevent a race where releasing
  /// focus from a previous sound kills the session for the current sound.
  Future<void> _ensureSessionActive() async {
    _focusReleaseTimer?.cancel();
    try {
      final session = await AudioSession.instance;
      await session.setActive(true);
    } catch (e) {
      debugError('[AUDIO] Failed to activate audio session: $e');
      // Continue anyway — playback may still work
    }
  }

  /// Schedule a delayed audio focus release.
  /// Debounced: if another sound plays within the delay window, the timer
  /// resets so focus stays active throughout rapid TX→RX sequences.
  /// Critical for Android Auto: eventually releases ducking so car audio resumes.
  void _scheduleFocusRelease() {
    _focusReleaseTimer?.cancel();
    _focusReleaseTimer = Timer(_focusReleaseDelay, () async {
      try {
        final session = await AudioSession.instance;
        await session.setActive(false);
        debugLog('[AUDIO] Audio focus released (debounced)');
      } catch (e) {
        debugError('[AUDIO] Failed to release audio focus: $e');
      }
    });
  }

  /// Reset audio session after a play() timeout
  /// Stops both players, reconfigures the audio session, and reloads assets
  Future<void> _resetAudioSession() async {
    _focusReleaseTimer?.cancel();
    try {
      // Stop both players
      await _txPlayer?.stop();
      await _rxPlayer?.stop();

      // Reconfigure audio session (same config as initialize())
      final session = await AudioSession.instance;
      await session.configure(
        const AudioSessionConfiguration(
          avAudioSessionCategory: AVAudioSessionCategory.ambient,
          avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.none,
          avAudioSessionMode: AVAudioSessionMode.defaultMode,
          avAudioSessionRouteSharingPolicy:
              AVAudioSessionRouteSharingPolicy.defaultPolicy,
          avAudioSessionSetActiveOptions: AVAudioSessionSetActiveOptions.none,
          androidAudioAttributes: AndroidAudioAttributes(
            contentType: AndroidAudioContentType.sonification,
            usage: AndroidAudioUsage.notification,
          ),
          androidAudioFocusGainType:
              AndroidAudioFocusGainType.gainTransientMayDuck,
          androidWillPauseWhenDucked: false,
        ),
      );

      // Reload assets so players are ready for next play()
      await _txPlayer?.setAsset(_txAsset);
      await _rxPlayer?.setAsset(_rxAsset);

      debugLog('[AUDIO] Audio session reset after timeout');
    } catch (e) {
      debugError('[AUDIO] Failed to reset audio session: $e');
    }
  }

  /// Play disconnect alert sound (triple beep pattern).
  /// Independent of master sound toggle — this is a safety alert.
  Future<void> playAlertSound() async {
    if (!_initialized || _txPlayer == null) return;

    try {
      await _ensureSessionActive();
      for (int i = 0; i < 3; i++) {
        await _txPlayer!.seek(Duration.zero);
        await _txPlayer!.play().timeout(const Duration(seconds: 3));
        if (i < 2) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      debugLog('[AUDIO] Played disconnect alert (triple beep)');
      _scheduleFocusRelease();
    } on TimeoutException {
      debugWarn('[AUDIO] Alert play() timed out — resetting audio session');
      await _txPlayer!.stop();
      await _resetAudioSession();
    } catch (e) {
      debugError('[AUDIO] Failed to play alert sound: $e');
    }
  }

  /// Enable or disable sound notifications
  Future<void> setEnabled(bool enabled) async {
    if (_enabled == enabled) return;

    _enabled = enabled;
    debugLog('[AUDIO] Sound notifications ${enabled ? 'enabled' : 'disabled'}');
    await _saveEnabledState();
  }

  /// Toggle sound notifications
  Future<void> toggle() async {
    await setEnabled(!_enabled);
  }

  /// Enable or disable TX sound notifications
  Future<void> setTxEnabled(bool enabled) async {
    if (_txEnabled == enabled) return;
    _txEnabled = enabled;
    debugLog('[AUDIO] TX sound ${enabled ? 'enabled' : 'disabled'}');
    await _saveSetting(_txEnabledKey, enabled);
  }

  /// Enable or disable RX sound notifications
  Future<void> setRxEnabled(bool enabled) async {
    if (_rxEnabled == enabled) return;
    _rxEnabled = enabled;
    debugLog('[AUDIO] RX sound ${enabled ? 'enabled' : 'disabled'}');
    await _saveSetting(_rxEnabledKey, enabled);
  }

  /// Save a single setting to Hive
  Future<void> _saveSetting(String key, dynamic value) async {
    final box = await _openBoxSafely(_prefsBoxName);
    if (box == null) return;
    try {
      await box.put(key, value);
    } catch (e) {
      debugError('[AUDIO] Failed to save $key: $e');
    }
  }

  /// Dispose of audio resources
  void dispose() {
    debugLog('[AUDIO] Disposing audio service');
    _focusReleaseTimer?.cancel();
    _focusReleaseTimer = null;
    _txPlayer?.dispose();
    _rxPlayer?.dispose();
    _txPlayer = null;
    _rxPlayer = null;
    _initialized = false;
  }
}
