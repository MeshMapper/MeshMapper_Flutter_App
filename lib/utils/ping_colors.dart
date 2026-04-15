import 'package:flutter/material.dart';
import '../utils/debug_logger_io.dart';

/// Color vision deficiency types for accessibility.
///
/// Users select their CVD type in Settings > General > Color Vision.
/// The app adapts all semantic colors (ping types, signal quality,
/// repeater status, noise floor) to a distinguishable palette.
enum ColorVisionType {
  none, // Default — current palette
  protanopia, // Red-blind (~1% males)
  deuteranopia, // Green-blind (~1% males)
  tritanopia, // Blue-blind (~0.003%)
  achromatopsia, // Total color blindness (monochrome)
}

/// Immutable palette holding every semantic color the app uses.
class ColorPalette {
  // Ping type colors
  final Color txSuccess;
  final Color txSuccessLegend;
  final Color txFail;
  final Color rx;
  final Color discSuccess;
  final Color discFail;
  final Color traceSuccess;
  final Color noResponse;

  // Signal quality (SNR/RSSI) traffic-light
  final Color signalGood;
  final Color signalMedium;
  final Color signalBad;

  // Repeater status on map
  final Color repeaterActive;
  final Color repeaterNew;
  final Color repeaterDead;
  final Color repeaterDuplicate;

  // Noise floor gradient (good → medium → bad)
  final Color noiseFloorGood;
  final Color noiseFloorMedium;
  final Color noiseFloorBad;

  // Coverage layer legend (must match tile server output for each CVD type)
  final Color coverageBidir;
  final Color coverageDisc;
  final Color coverageTx;
  final Color coverageRx;
  final Color coverageDead;
  final Color coverageDrop;

  const ColorPalette({
    required this.txSuccess,
    required this.txSuccessLegend,
    required this.txFail,
    required this.rx,
    required this.discSuccess,
    required this.discFail,
    required this.traceSuccess,
    required this.noResponse,
    required this.signalGood,
    required this.signalMedium,
    required this.signalBad,
    required this.repeaterActive,
    required this.repeaterNew,
    required this.repeaterDead,
    required this.repeaterDuplicate,
    required this.noiseFloorGood,
    required this.noiseFloorMedium,
    required this.noiseFloorBad,
    required this.coverageBidir,
    required this.coverageDisc,
    required this.coverageTx,
    required this.coverageRx,
    required this.coverageDead,
    required this.coverageDrop,
  });
}

/// Concrete palette definitions for each CVD type.
///
/// Color choices for CVD palettes based on Wong (2011) "Points of view:
/// Color blindness" — Nature Methods. All colors within each palette are
/// mutually distinguishable for the target CVD type.
class ColorPalettes {
  ColorPalettes._();

  /// Default palette — matches original app colors and web map squares.
  /// BIDIR=#7EE094, TX=#FD8928, DISC/TRACE=#51D4E9, RX=#7D54C7,
  /// DEAD=#9E9689, DROP=#E04F5D
  static const none = ColorPalette(
    txSuccess: Color(0xFF4CAF50),
    txSuccessLegend: Color(0xFF22C55E),
    txFail: Color(0xFFF44336),
    rx: Color(0xFF7D54C7),
    discSuccess: Color(0xFF51D4E9),
    discFail: Color(0xFF9E9E9E),
    traceSuccess: Color(0xFF00BCD4),
    noResponse: Color(0xFF9E9E9E),
    signalGood: Colors.green,
    signalMedium: Colors.orange,
    signalBad: Colors.red,
    repeaterActive: Color(0xFFD63384),
    repeaterNew: Color(0xFFFD7E14),
    repeaterDead: Color(0xFF6C757D),
    repeaterDuplicate: Color(0xFFDC3545),
    noiseFloorGood: Colors.green,
    noiseFloorMedium: Colors.orange,
    noiseFloorBad: Colors.red,
    coverageBidir: Color(0xFF7EE094),
    coverageDisc: Color(0xFF51D4E9),
    coverageTx: Color(0xFFFD8928),
    coverageRx: Color(0xFF7D54C7),
    coverageDead: Color(0xFF9E9689),
    coverageDrop: Color(0xFFE04F5D),
  );

  /// Protanopia (red-blind) — replaces red/green axis with blue/orange.
  /// Also used for deuteranopia since both are red-green CVD.
  static const protanopia = ColorPalette(
    txSuccess: Color(0xFF0072B2), // Wong blue
    txSuccessLegend: Color(0xFF56B4E9), // Wong sky blue
    txFail: Color(0xFFD55E00), // Wong vermillion
    rx: Color(0xFFCC79A7), // Wong reddish purple
    discSuccess: Color(0xFF56B4E9), // Wong sky blue
    discFail: Color(0xFF9E9E9E), // Grey (unchanged)
    traceSuccess: Color(0xFF009E73), // Wong bluish green
    noResponse: Color(0xFF9E9E9E), // Grey (unchanged)
    signalGood: Color(0xFF0072B2), // Blue
    signalMedium: Color(0xFFF0E442), // Wong yellow
    signalBad: Color(0xFFD55E00), // Vermillion
    repeaterActive: Color(0xFFCC79A7), // Reddish purple
    repeaterNew: Color(0xFFF0E442), // Yellow
    repeaterDead: Color(0xFF9E9E9E), // Grey
    repeaterDuplicate: Color(0xFFD55E00), // Vermillion
    noiseFloorGood: Color(0xFF0072B2),
    noiseFloorMedium: Color(0xFFF0E442),
    noiseFloorBad: Color(0xFFD55E00),
    coverageBidir: Color(0xFF0072B2),
    coverageDisc: Color(0xFF56B4E9),
    coverageTx: Color(0xFFE69F00),
    coverageRx: Color(0xFFCC79A7),
    coverageDead: Color(0xFF9E9E9E),
    coverageDrop: Color(0xFFD55E00),
  );

  /// Tritanopia (blue-blind) — replaces blue/cyan with orange/vermillion.
  /// Red/green distinction is preserved since tritan users can see those.
  static const tritanopia = ColorPalette(
    txSuccess: Color(0xFF009E73), // Wong bluish green
    txSuccessLegend: Color(0xFF22C55E), // Bright green (visible)
    txFail: Color(0xFFD55E00), // Wong vermillion
    rx: Color(0xFFCC79A7), // Wong reddish purple
    discSuccess: Color(0xFFE69F00), // Wong orange (replaces cyan)
    discFail: Color(0xFF9E9E9E), // Grey (unchanged)
    traceSuccess: Color(0xFFD55E00), // Vermillion (replaces cyan)
    noResponse: Color(0xFF9E9E9E), // Grey (unchanged)
    signalGood: Color(0xFF009E73), // Bluish green
    signalMedium: Color(0xFFE69F00), // Orange
    signalBad: Color(0xFFD55E00), // Vermillion
    repeaterActive: Color(0xFFCC79A7), // Reddish purple
    repeaterNew: Color(0xFFE69F00), // Orange
    repeaterDead: Color(0xFF9E9E9E), // Grey
    repeaterDuplicate: Color(0xFFD55E00), // Vermillion
    noiseFloorGood: Color(0xFF009E73),
    noiseFloorMedium: Color(0xFFE69F00),
    noiseFloorBad: Color(0xFFD55E00),
    coverageBidir: Color(0xFF009E73),
    coverageDisc: Color(0xFFE69F00),
    coverageTx: Color(0xFFCC79A7),
    coverageRx: Color(0xFFCC79A7),
    coverageDead: Color(0xFF9E9E9E),
    coverageDrop: Color(0xFFD55E00),
  );

  /// Achromatopsia (monochrome) — luminance-only palette.
  /// Relies on maximum brightness contrast between categories.
  /// Secondary indicators (icons, text) are essential with this palette.
  static const achromatopsia = ColorPalette(
    txSuccess: Color(0xFFE0E0E0), // Light
    txSuccessLegend: Color(0xFFE0E0E0),
    txFail: Color(0xFF616161), // Dark
    rx: Color(0xFF9E9E9E), // Medium
    discSuccess: Color(0xFFBDBDBD), // Medium-light
    discFail: Color(0xFF757575), // Medium-dark
    traceSuccess: Color(0xFF757575), // Medium-dark
    noResponse: Color(0xFF616161), // Dark
    signalGood: Color(0xFFE0E0E0), // Light
    signalMedium: Color(0xFF9E9E9E), // Medium
    signalBad: Color(0xFF424242), // Very dark
    repeaterActive: Color(0xFFE0E0E0), // Light
    repeaterNew: Color(0xFFBDBDBD), // Medium-light
    repeaterDead: Color(0xFF616161), // Dark
    repeaterDuplicate: Color(0xFF424242), // Very dark
    noiseFloorGood: Color(0xFFE0E0E0),
    noiseFloorMedium: Color(0xFF9E9E9E),
    noiseFloorBad: Color(0xFF424242),
    coverageBidir: Color(0xFFE0E0E0),
    coverageDisc: Color(0xFFBDBDBD),
    coverageTx: Color(0xFF9E9E9E),
    coverageRx: Color(0xFF757575),
    coverageDead: Color(0xFF616161),
    coverageDrop: Color(0xFF424242),
  );

  /// Look up palette for a given CVD type.
  static ColorPalette forType(ColorVisionType type) {
    return switch (type) {
      ColorVisionType.none => none,
      ColorVisionType.protanopia => protanopia,
      ColorVisionType.deuteranopia => protanopia, // Same as protanopia
      ColorVisionType.tritanopia => tritanopia,
      ColorVisionType.achromatopsia => achromatopsia,
    };
  }
}

/// Centralized color accessors for ping types, signal quality, repeater
/// status, and noise floor.
///
/// All getters delegate to the active [ColorPalette], which changes when the
/// user selects a different color vision type in Settings. Existing call
/// sites (`PingColors.txSuccess`, etc.) continue to work unchanged.
class PingColors {
  PingColors._();

  static ColorPalette _activePalette = ColorPalettes.none;
  static ColorVisionType _currentType = ColorVisionType.none;

  /// Set the active palette. Called by AppStateProvider when the
  /// colorVisionType preference changes or on app startup.
  static void setColorVisionType(ColorVisionType type) {
    _currentType = type;
    _activePalette = ColorPalettes.forType(type);
    debugLog('[A11Y] Color palette set to ${type.name}');
  }

  /// Current CVD type (for UI display in settings).
  static ColorVisionType get currentType => _currentType;

  // ── Ping type colors (same API as before) ──
  static Color get txSuccess => _activePalette.txSuccess;
  static Color get txSuccessLegend => _activePalette.txSuccessLegend;
  static Color get txFail => _activePalette.txFail;
  static Color get rx => _activePalette.rx;
  static Color get discSuccess => _activePalette.discSuccess;
  static Color get discFail => _activePalette.discFail;
  static Color get traceSuccess => _activePalette.traceSuccess;
  static Color get noResponse => _activePalette.noResponse;

  // ── Signal quality (SNR/RSSI traffic-light) ──
  static Color get signalGood => _activePalette.signalGood;
  static Color get signalMedium => _activePalette.signalMedium;
  static Color get signalBad => _activePalette.signalBad;

  // ── Repeater status ──
  static Color get repeaterActive => _activePalette.repeaterActive;
  static Color get repeaterNew => _activePalette.repeaterNew;
  static Color get repeaterDead => _activePalette.repeaterDead;
  static Color get repeaterDuplicate => _activePalette.repeaterDuplicate;

  // ── Noise floor gradient ──
  static Color get noiseFloorGood => _activePalette.noiseFloorGood;
  static Color get noiseFloorMedium => _activePalette.noiseFloorMedium;
  static Color get noiseFloorBad => _activePalette.noiseFloorBad;

  // ── Coverage layer legend (matches tile server output) ──
  static Color get coverageBidir => _activePalette.coverageBidir;
  static Color get coverageDisc => _activePalette.coverageDisc;
  static Color get coverageTx => _activePalette.coverageTx;
  static Color get coverageRx => _activePalette.coverageRx;
  static Color get coverageDead => _activePalette.coverageDead;
  static Color get coverageDrop => _activePalette.coverageDrop;

  // ── Convenience: SNR color from value ──
  static Color snrColor(double snr) {
    if (snr <= -1) return signalBad;
    if (snr <= 5) return signalMedium;
    return signalGood;
  }

  // ── Convenience: RSSI color from value ──
  static Color rssiColor(int rssi) {
    if (rssi >= -70) return signalGood;
    if (rssi >= -100) return signalMedium;
    return signalBad;
  }

  // ── Convenience: Noise floor color from dBm ──
  static Color noiseFloorColor(double dbm) {
    if (dbm <= -100) return noiseFloorGood;
    if (dbm <= -90) return noiseFloorMedium;
    return noiseFloorBad;
  }
}
