import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';
import 'package:mesh_mapper/services/meshcore/packet_metadata.dart';
import 'package:mesh_mapper/services/meshcore/packet_validator.dart';
import 'package:mesh_mapper/services/meshcore/rx_logger.dart';
import 'package:mesh_mapper/services/meshcore/tx_tracker.dart';
import 'package:mesh_mapper/services/meshcore/unified_rx_handler.dart';
import 'package:mesh_mapper/utils/debug_logger_io.dart';

/// A truncated packet off the air is routine. It is skipped with a plain
/// log line, not reported as an error with a stack trace.
void main() {
  PacketMetadata parse(List<int> bytes) => PacketMetadata.fromRawPacket(
        raw: Uint8List.fromList(bytes),
        snr: 5.0,
        rssi: -90,
      );

  test('a path longer than the packet throws PacketTooShortException', () {
    // Flood header, pathLen says 3 one-byte hops, only one hop byte present.
    expect(() => parse([0x15, 0x03, 0xAA]),
        throwsA(isA<PacketTooShortException>()));
  });

  test('an empty or header-only packet throws PacketTooShortException', () {
    expect(() => parse(const []), throwsA(isA<PacketTooShortException>()));
    expect(() => parse([0x15]), throwsA(isA<PacketTooShortException>()));
    // Transport flood needs 4 transport code bytes before pathLen.
    expect(() => parse([0x14, 0x00, 0x00]),
        throwsA(isA<PacketTooShortException>()));
  });

  test('a complete packet still parses', () {
    final m = parse([0x15, 0x01, 0xAA, 0x01, 0x02]);
    expect(m.pathHashCount, 1);
    expect(m.encryptedPayload, [0x01, 0x02]);
  });

  test('the unified handler skips a short packet without an error log',
      () async {
    final lines = <String>[];
    final originalPrint = debugPrint;
    DebugLogger.setEnabled(true);
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) lines.add(message);
    };
    addTearDown(() {
      debugPrint = originalPrint;
      DebugLogger.setEnabled(false);
    });

    final handler = UnifiedRxHandler(
      txTracker: TxTracker(),
      rxLogger: RxLogger(
        onRxEntry: (_) async {},
        getGpsLocation: () =>
            (lat: 0.0, lon: 0.0, altitude: const FixAltitude.unknown()),
      ),
      validator: PacketValidator(allowedChannels: const {}),
    );
    handler.startListening();

    await handler.handlePacket(
        Uint8List.fromList([0x15, 0x03, 0xAA]), 5.0, -90);

    expect(lines.where((l) => l.startsWith('ERROR:')), isEmpty);
    expect(lines.any((l) => l.contains('[UNIFIED RX]') && l.contains('short')),
        isTrue);
  });
}
