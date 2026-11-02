import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import '../models/log_entry.dart';
import '../models/noise_floor_session.dart';
import '../models/ping_data.dart';
import 'store_capture_route.dart';

// Debug-only "capture mode" data for the app store screenshots. Screenshots
// are taken on simulators with no radio, so a made-up wardrive is loaded in
// memory. Nothing here touches Hive, the API queue or any upload path.

/// Name of the config file looked up in the app's documents directory.
const storeCaptureFileName = 'store_capture.json';

/// Radio name shown in the header while capture mode is active.
const storeCaptureRadioName = 'Ottawa Mobile';

/// Repeater ids used when no repeaters have been loaded from the server.
const storeCaptureFallbackIds = [
  '4E5D',
  '77A1',
  'A2F3',
  'B914',
  'C3F0',
  '1D7E'
];

/// Device id stamped on every sample ping.
const _deviceId = 'store-capture';

/// Index of the route point whose TX is forced to be a miss, so a drive always
/// has at least one red ping whatever the random draw gives.
const _forcedMissIndex = 30;

/// Bottom-bar tab the capture opens on.
enum StoreCaptureScreen {
  map,
  log,
  history;

  /// Index of the tab in the main scaffold.
  int get tabIndex => index;
}

/// What the capture should show, read from [storeCaptureFileName].
class StoreCaptureConfig {
  /// Set once at startup when a valid config file was found.
  static StoreCaptureConfig? active;

  final StoreCaptureScreen screen;

  const StoreCaptureConfig({required this.screen});

  /// Parses the file body. Returns null for anything that is not a JSON object
  /// with a known `screen`.
  static StoreCaptureConfig? parse(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! Map<String, dynamic>) return null;
      final name = decoded['screen'];
      for (final screen in StoreCaptureScreen.values) {
        if (screen.name == name) return StoreCaptureConfig(screen: screen);
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Reads [storeCaptureFileName] from [documents]. Null when the file is
  /// missing or invalid.
  static Future<StoreCaptureConfig?> load(Directory documents) async {
    try {
      final file = File('${documents.path}/$storeCaptureFileName');
      if (!await file.exists()) return null;
      return parse(await file.readAsString());
    } catch (_) {
      return null;
    }
  }
}

/// The made-up drive: every list the Map, Log and History screens read, plus
/// the numbers shown in the header.
class StoreCaptureSample {
  final List<TxPing> txPings;
  final List<TxLogEntry> txLog;
  final List<RxPing> rxPings;
  final List<RxLogEntry> rxLog;
  final List<DiscLogEntry> disc;
  final List<TraceLogEntry> trace;
  final List<NoiseFloorSession> sessions;
  final PingStats stats;
  final int noiseFloor;
  final int batteryPercent;

  const StoreCaptureSample({
    required this.txPings,
    required this.txLog,
    required this.rxPings,
    required this.rxLog,
    required this.disc,
    required this.trace,
    required this.sessions,
    required this.stats,
    required this.noiseFloor,
    required this.batteryPercent,
  });
}

/// Builds the sample drive along [storeCaptureRoute]. The last point is the
/// newest TX, at [newest]; earlier points are 22 s apart. Repeaters heard come
/// from [repeaters] (nearest within 12 km), or from
/// [storeCaptureFallbackIds] when none are loaded. Same inputs, same output.
StoreCaptureSample buildStoreCaptureSample({
  required DateTime newest,
  required List<({String id, double lat, double lon})> repeaters,
}) {
  final rnd = math.Random(7);
  const route = storeCaptureRoute;
  final last = route.length - 1;

  double km(double la1, double lo1, double la2, double lo2) {
    final dy = (la2 - la1) * 111.0;
    final dx = (lo2 - lo1) * 111.0 * math.cos(la1 * math.pi / 180);
    return math.sqrt(dx * dx + dy * dy);
  }

  // 1 to 4 repeaters that could hear a ping at this spot, as (id, snr, rssi).
  List<(String, double, int)> heardAt(double lat, double lon) {
    final near = repeaters
        .map((r) => (r.id, km(lat, lon, r.lat, r.lon)))
        .where((e) => e.$2 < 12)
        .toList()
      ..sort((a, b) => a.$2.compareTo(b.$2));
    final n = 1 + rnd.nextInt(4);
    final List<(String, double)> picks;
    if (near.isNotEmpty) {
      picks = near.take(n).toList();
    } else {
      final start = rnd.nextInt(storeCaptureFallbackIds.length);
      picks = [
        for (var i = 0; i < n; i++)
          (
            storeCaptureFallbackIds[
                (start + i) % storeCaptureFallbackIds.length],
            1.0 + i * 2.5,
          ),
      ];
    }
    return picks.map((e) {
      final snr = (11 - e.$2 * 1.6 + rnd.nextDouble() * 3)
          .clamp(-14.0, 12.0)
          .toDouble();
      final rssi = (-58 - e.$2 * 6 - rnd.nextInt(8)).round();
      return (e.$1, double.parse(snr.toStringAsFixed(1)), rssi);
    }).toList();
  }

  final txPings = <TxPing>[];
  final txLog = <TxLogEntry>[];
  final rxPings = <RxPing>[];
  final rxLog = <RxLogEntry>[];

  for (var i = 0; i < route.length; i++) {
    final (lat, lon) = route[i];
    final ts = newest.subtract(Duration(seconds: (last - i) * 22));
    final miss = rnd.nextDouble() < 0.1 || i == _forcedMissIndex;
    final heard = miss ? <(String, double, int)>[] : heardAt(lat, lon);
    txPings.add(TxPing(
      latitude: lat,
      longitude: lon,
      power: 22,
      timestamp: ts,
      deviceId: _deviceId,
      heardRepeaters: [
        for (final h in heard)
          HeardRepeater(repeaterId: h.$1, snr: h.$2, rssi: h.$3),
      ],
    ));
    txLog.add(TxLogEntry(
      timestamp: ts,
      latitude: lat,
      longitude: lon,
      power: 1.0,
      events: [
        for (final h in heard) RxEvent(repeaterId: h.$1, snr: h.$2, rssi: h.$3),
      ],
    ));

    // An RX heard midway to the next point, 9 s after this one.
    if (i % 3 == 1) {
      final h = heardAt(lat, lon).first;
      final rts = ts.add(const Duration(seconds: 9));
      final (nLat, nLon) = route[math.min(i + 1, last)];
      final rLat = (lat + nLat) / 2;
      final rLon = (lon + nLon) / 2;
      rxPings.add(RxPing(
        latitude: rLat,
        longitude: rLon,
        repeaterId: h.$1,
        timestamp: rts,
        snr: h.$2,
        rssi: h.$3,
      ));
      rxLog.add(RxLogEntry(
        timestamp: rts,
        repeaterId: h.$1,
        snr: h.$2,
        rssi: h.$3,
        pathLength: 0,
        header: 0,
        latitude: rLat,
        longitude: rLon,
      ));
    }
  }

  final (dLat, dLon) = route[20];
  final disc = [
    DiscLogEntry(
      timestamp: newest.subtract(const Duration(minutes: 9)),
      latitude: dLat,
      longitude: dLon,
      noiseFloor: -111,
      discoveredNodes: [
        for (final h in heardAt(dLat, dLon))
          DiscoveredNodeEntry(
            repeaterId: h.$1,
            nodeType: 'REPEATER',
            localSnr: h.$2,
            localRssi: h.$3,
            remoteSnr: h.$2 - 1.5,
          ),
      ],
    ),
  ];

  final (tLat, tLon) = route[34];
  final th = heardAt(tLat, tLon).first;
  final trace = [
    TraceLogEntry(
      timestamp: newest.subtract(const Duration(minutes: 4)),
      latitude: tLat,
      longitude: tLon,
      targetRepeaterId: th.$1,
      noiseFloor: -110,
      localSnr: th.$2,
      remoteSnr: th.$2 - 2,
      localRssi: th.$3,
      success: true,
    ),
  ];

  // Four finished sessions on the days before, newest first.
  const modes = ['active', 'hybrid', 'passive', 'active'];
  final sessions = <NoiseFloorSession>[];
  for (var s = 0; s < modes.length; s++) {
    final start = newest.subtract(Duration(days: s + 1, hours: 2 + s * 3));
    final mins = 18 + s * 11;
    final samples = <NoiseFloorSample>[];
    for (var k = 0; k < mins * 6; k++) {
      final bump = (k % 90 > 70) ? 6 : 0;
      samples.add(NoiseFloorSample(
        timestamp: start.add(Duration(seconds: k * 10)),
        noiseFloor: -112 + rnd.nextInt(5) + bump,
      ));
    }
    final markers = <PingEventMarker>[];
    for (var k = 0; k < mins; k++) {
      final (lat, lon) = route[(k * 2 + s * 5) % route.length];
      final ok = rnd.nextDouble() > 0.15;
      markers.add(PingEventMarker(
        timestamp: start.add(Duration(minutes: k)),
        type: ok
            ? (k % 4 == 0 ? PingEventType.rx : PingEventType.txSuccess)
            : PingEventType.txFail,
        noiseFloor: -111 + rnd.nextInt(4),
        latitude: lat,
        longitude: lon,
        repeaters: ok
            ? [
                for (final h in heardAt(lat, lon))
                  MarkerRepeaterInfo(repeaterId: h.$1, snr: h.$2, rssi: h.$3),
              ]
            : null,
      ));
    }
    sessions.add(NoiseFloorSession(
      id: 'store-capture-$s',
      startTime: start,
      endTime: start.add(Duration(minutes: mins)),
      mode: modes[s],
      samples: samples,
      markers: markers,
    ));
  }

  return StoreCaptureSample(
    txPings: txPings,
    txLog: txLog,
    rxPings: rxPings,
    rxLog: rxLog,
    disc: disc,
    trace: trace,
    sessions: sessions,
    stats: PingStats(
      txCount: txPings.length,
      rxCount: rxPings.length,
      discCount: disc.length,
      traceCount: trace.length,
      successfulUploads: txPings.length + rxPings.length,
    ),
    noiseFloor: -109,
    batteryPercent: 86,
  );
}
