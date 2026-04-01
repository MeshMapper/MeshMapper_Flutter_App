import 'package:flutter/material.dart';

/// Centralized color constants for ping types (TX, RX, DISC, Trace).
///
/// Dot/marker colors are aligned with coverage layer squares on the
/// MeshMapper web map:
///   BIDIR=#7EE094, TX=#FD8928, DISC/TRACE=#51D4E9, RX=#7D54C7,
///   DEAD=#9E9689, DROP=#E04F5D
class PingColors {
  PingColors._();

  // ── TX (green — we can't distinguish BIDIR vs TX client-side) ──
  static const Color txSuccess = Color(0xFF4CAF50);
  static const Color txSuccessLegend = Color(0xFF22C55E);
  static const Color txFail = Color(0xFFF44336);

  // ── RX (purple — matches RX web map squares #7D54C7) ──
  static const Color rx = Color(0xFF7D54C7);

  // ── DISC (cyan — matches DISC/TRACE web map squares #51D4E9) ──
  static const Color discSuccess = Color(0xFF51D4E9);
  static const Color discFail = Color(0xFF9E9E9E);

  // ── Trace (cyan family — same web map layer as DISC) ──
  static const Color traceSuccess = Color(0xFF00BCD4);

  // ── Shared ──
  static const Color noResponse = Color(0xFF9E9E9E);
}
