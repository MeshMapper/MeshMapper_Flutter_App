/// What one scope request came to, as the log tab shows it.
///
/// Only requests a repeater answered or refused are logged. A local failure,
/// an abort, a cancel or the distance gate never reached a repeater and stay
/// debug log lines.
enum ScopeLogOutcome {
  /// The repeater answered with its scope list (possibly empty).
  answered,

  /// The request went out and no answer came back in time.
  noResponse,

  /// The radio flooded the request instead of sending it direct.
  flooded,

  /// The repeater answered with something that is not a scope list.
  malformed,

  /// The radio refused a step with an error code.
  radioError,

  /// The radio refused the send because the repeater is not a saved contact
  /// and its contact table is full (companion firmware bug, fixed in
  /// v1.17.0). Set only for that exact case; every other ERR is
  /// [radioError].
  radioContactsFull,

  /// The repeater answered, but this device's hourly upload cap was full.
  withheldHourlyCap,
}

extension ScopeLogOutcomeLabel on ScopeLogOutcome {
  /// The outcome in plain words, as the log card shows it.
  String get label => switch (this) {
        ScopeLogOutcome.answered => 'Answered',
        ScopeLogOutcome.noResponse => 'No response from repeater',
        ScopeLogOutcome.flooded => 'Sent as a flood by the radio',
        ScopeLogOutcome.malformed => 'Unreadable answer',
        ScopeLogOutcome.radioError => 'Radio error',
        ScopeLogOutcome.radioContactsFull => 'Radio contact list full',
        ScopeLogOutcome.withheldHourlyCap =>
          'Not uploaded: hourly limit reached',
      };
}

/// One scope request in the log.
class ScopeLogEntry {
  /// When the outcome was known (the answer's arrival for an answer).
  final DateTime timestamp;

  /// The discovery point the repeater was found from.
  final double latitude;
  final double longitude;

  /// The short repeater id, as the discovery that found it printed it.
  final String repeaterId;

  /// The repeater's full public key, upper-case hex.
  final String pubkeyHex;

  final ScopeLogOutcome outcome;

  /// The scope names exactly as received, for [ScopeLogOutcome.answered] and
  /// [ScopeLogOutcome.withheldHourlyCap]; null otherwise.
  final List<String>? scopes;

  const ScopeLogEntry({
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.repeaterId,
    required this.pubkeyHex,
    required this.outcome,
    this.scopes,
  });

  /// Get formatted timestamp (HH:MM:SS)
  String get timeString {
    return '${timestamp.hour.toString().padLeft(2, '0')}:'
        '${timestamp.minute.toString().padLeft(2, '0')}:'
        '${timestamp.second.toString().padLeft(2, '0')}';
  }

  /// Get formatted location (5 decimal places)
  String get locationString {
    return '${latitude.toStringAsFixed(5)},${longitude.toStringAsFixed(5)}';
  }

  /// Get CSV row: timestamp, lat, lon, repeater id, outcome (raw enum name),
  /// then the scope names semicolon-joined in one quoted field (empty when
  /// [scopes] is null or carries none).
  String toCsv() {
    final scopesStr = (scopes ?? const <String>[]).join(';');
    return '${timestamp.toIso8601String()},$latitude,$longitude,$repeaterId,'
        '${outcome.name},"$scopesStr"';
  }
}

/// The scope log's own list state: newest-first insertion capped at
/// [maxEntries], and a clear. `AppStateProvider` owns one instance and
/// delegates `_addScopeLogEntry`, `clearLogs` and `clearPings` to it, so the
/// add/cap/clear behaviour is unit-testable without constructing the
/// provider, and the provider's three call sites are each one line.
class ScopeLogStore {
  /// The most entries kept before the oldest is dropped.
  final int maxEntries;

  final List<ScopeLogEntry> _entries = [];

  ScopeLogStore({this.maxEntries = 500});

  /// Every logged entry, newest first.
  List<ScopeLogEntry> get entries => List.unmodifiable(_entries);

  /// Inserts [entry] at the front, then drops the oldest entry once the
  /// list grows past [maxEntries].
  void add(ScopeLogEntry entry) {
    _entries.insert(0, entry);
    if (_entries.length > maxEntries) {
      _entries.removeLast();
    }
  }

  /// Empties the list. Called by `clearLogs` and `clearPings`.
  void clear() => _entries.clear();
}
