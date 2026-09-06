import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../utils/coverage_tile_palette.dart';
import '../external_surfaces/external_surface_color.dart';
import '../external_surfaces/geo/external_surface_geo_models.dart';

import '../../utils/debug_logger_io.dart';

typedef CarMapSettingsBuilder = CarMapSettings Function();

@immutable
class CarMapSettings {
  const CarMapSettings({
    required this.styleUrl,
    required this.coverage,
    required this.northUp,
    required this.markerStyle,
    required this.markerFacesHeading,
    required this.nodeName,
  });


  final String styleUrl;
  final CarMapCoverage? coverage;
  final bool northUp;
  final String markerStyle;
  final bool markerFacesHeading;
  final String? nodeName;

  static CarMapSettings from({
    required String styleUrl,
    required String? zoneCode,
    required bool tilesEnabled,
    required int gridSize,
    required String colorVisionType,
    required double opacity,
    required bool mapAlwaysNorth,
    required bool mapRotationLocked,
    required String markerStyle,
    required bool markerFacesHeading,
    String? nodeName,
  }) =>
      CarMapSettings(
        styleUrl: styleUrl,
        coverage: CarMapCoverage.forZone(
          zoneCode: zoneCode,
          tilesEnabled: tilesEnabled,
          gridSize: gridSize,
          colorVisionType: colorVisionType,
          opacity: opacity,
        ),
        northUp: mapAlwaysNorth || mapRotationLocked,
        markerStyle: markerStyle,
        markerFacesHeading: markerFacesHeading,
        nodeName: nodeName,
      );
}

@immutable
class CarMapCoverage {
  const CarMapCoverage({
    required this.tileUrl,
    required this.fillColor,
    required this.outlineColor,
    required this.opacity,
    this.minZoom = 7,
    this.maxZoom = 14,
  });

  final String tileUrl;

  final String fillColor;
  final String outlineColor;

  final double opacity;
  final double minZoom;
  final double maxZoom;

  static CarMapCoverage? forZone({
    required String? zoneCode,
    required int gridSize,
    required String colorVisionType,
    required double opacity,
    bool tilesEnabled = true,
  }) {

    if (!tilesEnabled) return null;
    if (zoneCode == null || zoneCode.isEmpty || opacity <= 0) return null;
    final zone = zoneCode.toLowerCase();
    return CarMapCoverage(
      tileUrl:
          'https://$zone.meshmapper.net/vector_tile.php?z={z}&x={x}&y={y}&gsize=$gridSize',
      fillColor: jsonEncode(
        CoverageTilePalette.fillColorExpression(colorVisionType),
      ),
      outlineColor: jsonEncode(
        CoverageTilePalette.borderColorExpression(colorVisionType),
      ),
      opacity: opacity,
    );
  }

  Map<String, Object?> toArguments() => {
        'tileUrl': tileUrl,
        'fillColor': fillColor,
        'outlineColor': outlineColor,
        'opacity': opacity,
        'minZoom': minZoom,
        'maxZoom': maxZoom,
      };

  @override
  bool operator ==(Object other) =>
      other is CarMapCoverage &&
      other.tileUrl == tileUrl &&
      other.fillColor == fillColor &&
      other.outlineColor == outlineColor &&
      other.opacity == opacity &&
      other.minZoom == minZoom &&
      other.maxZoom == maxZoom;

  @override
  int get hashCode => Object.hash(
        tileUrl,
        fillColor,
        outlineColor,
        opacity,
        minZoom,
        maxZoom,
      );
}

class CarMapChannel {
  CarMapChannel({@visibleForTesting MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(_channelName);

  static const String _channelName = 'meshmapper/car_map';

  final MethodChannel _channel;

  double? _lastLat;
  double? _lastLon;
  double? _lastHeading;
  String? _lastMarkerStyle;
  CarMapCoverage? _lastCoverage;
  bool _hasSentCoverage = false;
  String? _lastPings;
  String? _lastTimer;

  Future<void> setCamera({
    required double lat,
    required double lon,
    double? bearing,
    double? heading,
    double? zoom,
  }) async {
    // Heading is part of the dedupe: standing still while turning still has to
    // move the marker.
    if (_sameToFiveDecimals(lat, _lastLat) &&
        _sameToFiveDecimals(lon, _lastLon) &&
        heading == _lastHeading) {
      return;
    }
    _lastLat = lat;
    _lastLon = lon;
    _lastHeading = heading;
    await _invoke('setCamera', {
      'lat': lat,
      'lon': lon,
      'bearing': bearing,
      'heading': heading,
      'zoom': zoom,
    });
  }

  Future<void> setStyle(String url) async {
    if (url.isEmpty) return;
    await _invoke('setStyle', {'url': url});
  }

  Future<void> setCoverage(CarMapCoverage? coverage) async {
    if (_hasSentCoverage && coverage == _lastCoverage) return;
    _hasSentCoverage = true;
    _lastCoverage = coverage;
    await _invoke('setCoverage', coverage?.toArguments() ?? const {});
  }

  Future<void> setPings(List<ExternalSurfacePing> pings) async {
    final geoJson = encodePingsGeoJson(pings);
    if (geoJson == _lastPings) return;
    _lastPings = geoJson;
    await _invoke('setPings', {'geoJson': geoJson});
  }

  Future<void> setTimer({
    DateTime? endsAt,
    int? durationMs,
    int? argbColor,
  }) async {
    final key = '${endsAt?.millisecondsSinceEpoch}|$durationMs|$argbColor';
    if (key == _lastTimer) return;
    _lastTimer = key;
    await _invoke('setTimer', {
      'endsAtMs': endsAt?.millisecondsSinceEpoch,
      'durationMs': durationMs,
      'color': argbColor,
    });
  }

  Future<void> setPositionMarker({
    required String style,
    required Uint8List png,
    required bool facesHeading,
  }) async {
    if (style == _lastMarkerStyle) return;
    _lastMarkerStyle = style;
    await _invoke('setPositionMarker', {
      'png': png,
      'facesHeading': facesHeading,
    });
  }

  Future<void> _invoke(String method, Map<String, Object?> args) async {
    try {
      await _channel.invokeMethod<bool>(method, args);
    } on MissingPluginException {
    } catch (e) {
      debugLog('[AUTO] Car map $method failed: $e');
    }
  }

  static bool _sameToFiveDecimals(double value, double? previous) =>
      previous != null && (value - previous).abs() < 0.00001;
}

String encodePingsGeoJson(List<ExternalSurfacePing> pings) => jsonEncode({
      'type': 'FeatureCollection',
      'features': [
        for (final ping in pings)
          {
            'type': 'Feature',
            'geometry': {
              'type': 'Point',
              'coordinates': [ping.lon, ping.lat],
            },
            'properties': {
              'color': _hex(ping.color),
              'kind': ping.kind,
            },
          },
      ],
    });

String _hex(ExternalSurfaceColor color) {
  String channel(double v) =>
      (v * 255.0).round().clamp(0, 255).toRadixString(16).padLeft(2, '0');
  return '#${channel(color.r)}${channel(color.g)}${channel(color.b)}';
}
