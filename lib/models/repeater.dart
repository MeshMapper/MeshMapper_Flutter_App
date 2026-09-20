import 'package:intl/intl.dart';

/// Represents a repeater from the MeshMapper API.
/// Used to display repeater markers on the map.
class Repeater {
  /// Zone-level fallback for stale threshold, updated from the status API's
  /// `stale_repeater_hours` field. Used only when a repeater lacks a
  /// per-repeater [staleTime].
  static int staleHoursFallback = 24;

  /// Advertised short ID. This can collide with another repeater.
  final String id;

  /// Full public key. This is the repeater's unique identity.
  final String hexId;

  /// Display name of the repeater
  final String name;

  /// Latitude coordinate
  final double lat;

  /// Longitude coordinate
  final double lon;

  /// Last heard timestamp (Unix seconds)
  final int lastHeard;

  /// Enabled status (1 = enabled, 0 = disabled)
  final int enabled;

  /// IATA zone code (e.g., "YOW")
  final String? iata;

  /// Created at timestamp (Unix seconds), nullable for backwards compatibility
  final int? createdAt;

  /// Server-provided staleness cutoff (Unix seconds).
  /// The repeater is active while `now < staleTime`.
  final int? staleTime;

  /// Number of bytes per hop hash for this repeater's path (1, 2, or 3)
  final int hopBytes;

  /// Number of bytes this repeater advertises as its on-air ID.
  /// Falls back to [hopBytes] for older server payloads.
  final int advertBytes;

  /// Whether this repeater can be addressed with a multi-byte ID.
  final bool multibyteCapable;

  /// Repeater clock skew in seconds reported by the server (+ve = repeater
  /// clock behind real time, -ve = ahead), or null when unknown. Drives the
  /// "time is not set correctly" warning in the detail sheet.
  final int? timeOffset;

  /// Display names of the repeater's administrators. Empty when the server
  /// list predates this field or the repeater has none.
  final List<String> admins;

  /// Whether the server ranks this repeater as part of its region's backbone:
  /// the smallest set of repeaters carrying half the region's traffic.
  ///
  /// **Never computed here.** Scoring is whole-pool, over every repeater in a
  /// region ranked by its share of the region's summed link counts. The app
  /// fetches a zone's repeaters, not a region's traffic, so scoring locally
  /// over whatever it happens to hold would give a different answer from the
  /// one the web shows for the same area. Read the server's verdict or show
  /// nothing.
  ///
  /// The field is added lazily server-side, so it is **absent** rather than
  /// null in three ordinary cases: a server that predates it, a region whose
  /// background job has not run, and a region too quiet to score. Absent means
  /// "not backbone", it is the expected state, and it is never logged or
  /// surfaced.
  final bool backbone;

  /// This repeater's own share of its region's traffic, 0..1, or null when the
  /// server did not say. Stable and refreshed on the order of hours, so it is
  /// never polled.
  final double? backboneShare;

  /// The site details an administrator fills in about their installation.
  /// Every one is additive, optional and free text the server does not
  /// validate, so they are null on most repeaters and on any server that
  /// predates them. Null is the expected state and is never logged.
  ///
  /// The radio model, e.g. `Station G3` or `RAK WisBlock 4631`.
  final String? hardware;

  /// The antenna, e.g. `Seeed 8dBi`.
  final String? antenna;

  /// How high the antenna is mounted, in metres. The server sends whole and
  /// fractional values alike (`40`, `22.9`).
  final double? heightMeters;

  /// Transmit power exactly as the administrator typed it. Inconsistent by
  /// nature (`0.3`, `0.3w`, `1.0W` are all real stored values), so read
  /// [displayPower] rather than this.
  final String? power;

  /// How the site is powered: `solar`, `poe` or `mains` as stored. Read
  /// [displayPowerSource] for the cased form.
  final String? powerSource;

  /// The administrator's free-text description of the installation.
  final String? siteNotes;

  /// The radio preset this repeater is currently heard on, as the server's
  /// `freq,bw,sf` tag (e.g. `910.525,62.5,7`). Note it is three slots, not the
  /// four of the app's own radio configuration tag: the coding rate is left
  /// out, exactly as the `f_freq`/`f_bw`/`f_sf` filter leaves it out. Read
  /// [displayPreset] for the readable form.
  final String? presetCurrent;

  const Repeater({
    required this.id,
    required this.hexId,
    required this.name,
    required this.lat,
    required this.lon,
    required this.lastHeard,
    required this.enabled,
    this.iata,
    this.createdAt,
    this.staleTime,
    this.hopBytes = 1,
    int? advertBytes,
    this.multibyteCapable = false,
    this.timeOffset,
    this.admins = const [],
    this.backbone = false,
    this.backboneShare,
    this.hardware,
    this.antenna,
    this.heightMeters,
    this.power,
    this.powerSource,
    this.siteNotes,
    this.presetCurrent,
  }) : advertBytes = advertBytes ?? hopBytes;

  /// Parse from JSON object in repeaters.json
  factory Repeater.fromJson(Map<String, dynamic> json) {
    // Parse created_at which may be int or String
    int? createdAt;
    final rawCreatedAt = json['created_at'];
    if (rawCreatedAt is int) {
      createdAt = rawCreatedAt;
    } else if (rawCreatedAt is String) {
      createdAt = int.tryParse(rawCreatedAt);
    }

    // Parse stale_time which may be int or String
    int? staleTime;
    final rawStaleTime = json['stale_time'];
    if (rawStaleTime is int) {
      staleTime = rawStaleTime;
    } else if (rawStaleTime is String) {
      staleTime = int.tryParse(rawStaleTime);
    }

    // Parse time_offset (repeater clock skew, seconds) which may be int or String
    int? timeOffset;
    final rawTimeOffset = json['time_offset'];
    if (rawTimeOffset is int) {
      timeOffset = rawTimeOffset;
    } else if (rawTimeOffset is num) {
      timeOffset = rawTimeOffset.toInt();
    } else if (rawTimeOffset is String) {
      timeOffset = int.tryParse(rawTimeOffset);
    }

    final rawAdmins = json['admins'];
    final admins = rawAdmins is List ? rawAdmins.whereType<String>().toList() : const <String>[];

    // Absent is the normal case and means "not backbone": no log line, no
    // user-visible anything. 1/true/"1" are all accepted because the field
    // crosses PHP.
    final rawBackbone = json['backbone'];
    final backbone = rawBackbone == 1 ||
        rawBackbone == true ||
        rawBackbone == '1' ||
        (rawBackbone is num && rawBackbone == 1);
    final rawShare = json['backbone_share'];
    final shareValue = rawShare is num
        ? rawShare
        : rawShare is String
            ? num.tryParse(rawShare)
            : null;
    final backboneShare =
        shareValue == null || !shareValue.isFinite ? null : shareValue.toDouble();

    final rawHopBytes = json['hop_bytes'];
    final hopBytes = rawHopBytes is num
        ? rawHopBytes.toInt()
        : int.tryParse(rawHopBytes?.toString() ?? '') ?? 1;
    final rawAdvertBytes = json['advert_bytes'];
    final advertBytes = rawAdvertBytes is num
        ? rawAdvertBytes.toInt()
        : int.tryParse(rawAdvertBytes?.toString() ?? '') ?? hopBytes;
    final rawMultibyteCapable = json['multibyte_capable'];
    final multibyteCapable = rawMultibyteCapable == true ||
        rawMultibyteCapable == 1 ||
        rawMultibyteCapable == '1';

    // Admin-entered site details. Free text the server does not validate, so a
    // blank is read as "not filled in" and a non-string is ignored rather than
    // stringified into something like "true" on the row.
    String? text(String key) {
      final raw = json[key];
      if (raw is! String) return null;
      final trimmed = raw.trim();
      return trimmed.isEmpty ? null : trimmed;
    }

    final rawHeight = json['height_m'];
    final heightValue = rawHeight is num
        ? rawHeight
        : rawHeight is String
            ? num.tryParse(rawHeight.trim())
            : null;
    final heightMeters = heightValue == null || !heightValue.isFinite
        ? null
        : heightValue.toDouble();

    return Repeater(
      id: json['id'] as String,
      hexId: json['hex_id'] as String? ?? '',
      name: json['name'] as String? ?? 'Unknown',
      lat: (json['lat'] as num).toDouble(),
      lon: (json['lon'] as num).toDouble(),
      lastHeard: json['last_heard'] as int? ?? 0,
      enabled: json['enabled'] as int? ?? 0,
      iata: json['iata'] as String?,
      createdAt: createdAt,
      staleTime: staleTime,
      hopBytes: hopBytes,
      advertBytes: advertBytes,
      multibyteCapable: multibyteCapable,
      timeOffset: timeOffset,
      admins: admins,
      backbone: backbone,
      backboneShare: backboneShare,
      hardware: text('hardware'),
      antenna: text('antenna'),
      heightMeters: heightMeters,
      power: text('power'),
      powerSource: text('power_source'),
      siteNotes: text('site_notes'),
      presetCurrent: text('preset_current'),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'hex_id': hexId,
      'name': name,
      'lat': lat,
      'lon': lon,
      'last_heard': lastHeard,
      'enabled': enabled,
      'iata': iata,
      'created_at': createdAt,
      'stale_time': staleTime,
      'hop_bytes': hopBytes,
      'advert_bytes': advertBytes,
      'multibyte_capable': multibyteCapable ? 1 : 0,
      'time_offset': timeOffset,
      'admins': admins,
      // Round-tripped only when set, so a cached list keeps the same "absent
      // means not backbone" shape the server sends.
      if (backbone) 'backbone': 1,
      if (backboneShare != null) 'backbone_share': backboneShare,
      // Same rule for the site details: absent means "not filled in", so an
      // unset one must not come back as an explicit null.
      if (hardware != null) 'hardware': hardware,
      if (antenna != null) 'antenna': antenna,
      if (heightMeters != null) 'height_m': heightMeters,
      if (power != null) 'power': power,
      if (powerSource != null) 'power_source': powerSource,
      if (siteNotes != null) 'site_notes': siteNotes,
      if (presetCurrent != null) 'preset_current': presetCurrent,
    };
  }

  /// Get formatted last heard date/time (locale-aware)
  String get lastHeardFormatted {
    if (lastHeard == 0) return 'Never';
    final date = DateTime.fromMillisecondsSinceEpoch(lastHeard * 1000);
    return DateFormat.yMMMd().add_jm().format(date);
  }

  /// Check if the repeater is enabled (any non-zero value)
  bool get isEnabled => enabled != 0;

  /// Whether the web client treats this repeater as anonymized.
  bool get isHidden => name.startsWith('🚫') || name.endsWith('🚫');

  /// True when the repeater has known GPS coordinates. The API uses
  /// `(0, 0)` as a sentinel for "location not yet published" — those
  /// repeaters are excluded from map focus geometry (no line, no
  /// distance label, not part of the bounds-fit) but still appear in
  /// heard-repeater listings with a `location_off` indicator.
  bool get hasLocation => lat != 0.0 || lon != 0.0;

  /// Check if the repeater was created within the past 7 days
  bool get isNew {
    if (createdAt == null) return false;
    final created = DateTime.fromMillisecondsSinceEpoch(createdAt! * 1000);
    return DateTime.now().difference(created).inDays < 7;
  }

  /// Check if the repeater is active.
  /// Uses server-provided [staleTime] when available, otherwise falls back
  /// to [staleHoursFallback] (set from the zone's `stale_repeater_hours`).
  bool get isActive {
    if (staleTime != null) {
      final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      return nowSeconds < staleTime!;
    }
    if (lastHeard == 0) return false;
    final heard = DateTime.fromMillisecondsSinceEpoch(lastHeard * 1000);
    return DateTime.now().difference(heard).inHours < staleHoursFallback;
  }

  /// Check if the repeater has not been heard in the past 24 hours
  bool get isDead => !isActive;

  /// True when this repeater should be drawn in the backbone accent.
  ///
  /// Backbone replaces the active colour and never stacks with another state,
  /// so a stale or ambiguous repeater keeps its own colour even if the server
  /// marks it.
  bool get isBackbone => backbone && isActive;

  /// [power] with its unit normalised for display: `0.3` and `0.3w` both read
  /// as `0.3W`. The column is typed by hand into a free-text field, and all
  /// four spellings are real stored values, so the app tidies what it can
  /// recognise and shows anything else exactly as the administrator wrote it
  /// rather than guessing at a unit that may not be watts.
  String? get displayPower {
    final raw = power;
    if (raw == null) return null;
    if (RegExp(r'^\d+(\.\d+)?$').hasMatch(raw)) return '${raw}W';
    if (RegExp(r'^\d+(\.\d+)?w$').hasMatch(raw)) {
      return '${raw.substring(0, raw.length - 1)}W';
    }
    return raw;
  }

  /// [powerSource] cased for display. The three the server stores are lower
  /// case; an unrecognised one is capitalised rather than dropped, since the
  /// field is free text and a new value is more useful shown than hidden.
  String? get displayPowerSource {
    final raw = powerSource;
    if (raw == null) return null;
    switch (raw.toLowerCase()) {
      case 'solar':
        return 'Solar';
      case 'poe':
        return 'PoE';
      case 'mains':
        return 'Mains';
      default:
        return raw[0].toUpperCase() + raw.substring(1);
    }
  }

  /// [presetCurrent] as readable radio settings: `910.525,62.5,7` becomes
  /// `910.525 MHz · 62.5 kHz · SF7`. A tag that is not exactly three numeric
  /// slots is shown as stored, so a server that changes the shape degrades to
  /// the raw string instead of rendering a half-parsed line.
  String? get displayPreset {
    final raw = presetCurrent;
    if (raw == null) return null;
    final slots = raw.split(',').map((s) => s.trim()).toList();
    if (slots.length != 3) return raw;
    final numeric = RegExp(r'^\d+(\.\d+)?$');
    if (slots.any((s) => !numeric.hasMatch(s))) return raw;
    return '${slots[0]} MHz · ${slots[1]} kHz · SF${slots[2]}';
  }

  /// True if the repeater has been heard within the past 30 days. Used by
  /// the map to hide long-stale repeaters. Returns false when [lastHeard]
  /// is 0 (never heard).
  bool get isHeardRecently {
    if (lastHeard == 0) return false;
    final heard = DateTime.fromMillisecondsSinceEpoch(lastHeard * 1000);
    return DateTime.now().difference(heard).inDays < 30;
  }

  /// Get the on-air display ID, using this repeater's advertised byte width.
  /// [overrideHopBytes] preserves the explicit regional override used by older
  /// callers, but does not affect the default width.
  String displayHexId({int? overrideHopBytes}) {
    final bytes = overrideHopBytes ?? advertBytes;
    final hexChars = bytes * 2; // 1 byte = 2 hex chars
    final cleanHex = hexId
        .replaceAll('!', '')
        .replaceAll(RegExp('0x', caseSensitive: false), '')
        .toLowerCase();
    if (cleanHex.isNotEmpty) {
      final end = cleanHex.length < hexChars ? cleanHex.length : hexChars;
      return cleanHex.substring(0, end).toUpperCase();
    }
    return id.toUpperCase();
  }

  Repeater copyWith({
    String? id,
    String? hexId,
    String? name,
    double? lat,
    double? lon,
    int? lastHeard,
    int? enabled,
    String? iata,
    int? createdAt,
    int? staleTime,
    int? hopBytes,
    int? advertBytes,
    bool? multibyteCapable,
    int? timeOffset,
    List<String>? admins,
    bool? backbone,
    double? backboneShare,
    String? hardware,
    String? antenna,
    double? heightMeters,
    String? power,
    String? powerSource,
    String? siteNotes,
    String? presetCurrent,
  }) =>
      Repeater(
        id: id ?? this.id,
        hexId: hexId ?? this.hexId,
        name: name ?? this.name,
        lat: lat ?? this.lat,
        lon: lon ?? this.lon,
        lastHeard: lastHeard ?? this.lastHeard,
        enabled: enabled ?? this.enabled,
        iata: iata ?? this.iata,
        createdAt: createdAt ?? this.createdAt,
        staleTime: staleTime ?? this.staleTime,
        hopBytes: hopBytes ?? this.hopBytes,
        advertBytes: advertBytes ?? this.advertBytes,
        multibyteCapable: multibyteCapable ?? this.multibyteCapable,
        timeOffset: timeOffset ?? this.timeOffset,
        admins: admins ?? this.admins,
        backbone: backbone ?? this.backbone,
        backboneShare: backboneShare ?? this.backboneShare,
        hardware: hardware ?? this.hardware,
        antenna: antenna ?? this.antenna,
        heightMeters: heightMeters ?? this.heightMeters,
        power: power ?? this.power,
        powerSource: powerSource ?? this.powerSource,
        siteNotes: siteNotes ?? this.siteNotes,
        presetCurrent: presetCurrent ?? this.presetCurrent,
      );

  @override
  String toString() => 'Repeater(id=$id, name=$name, enabled=$isEnabled)';
}
