import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';
import 'package:mesh_mapper/services/meshcore/packet_metadata.dart';
import 'package:mesh_mapper/services/meshcore/packet_validator.dart';
import 'package:mesh_mapper/services/meshcore/rx_logger.dart';

/// A direct packet's path is the route it still has to travel, not the hops
/// it came through. A user heard a nearby radio's login request addressed via
/// 7463 then 850C at RSSI 0, and the app blamed 850C (15 km away) as a
/// possible carpeater. These bytes are that packet from the log.
void main() {
  // Path 7463 -> 850C (2 hops, 2 bytes each), then the ANON_REQ payload.
  const pathAndPayload = [
    0x42, 0x74, 0x63, 0x85, 0x0C, 0xD1, 0x88, 0x9E, 0x55, 0x36, 0xCE, //
    0xFC, 0x27, 0x39, 0x6C, 0xE4, 0xE3, 0x05, 0xCF, 0x54, 0x91, 0x1C,
    0x87, 0x78, 0x51, 0xA6, 0xE4, 0x0A, 0x95, 0xA9, 0x8E, 0x78, 0x3D,
  ];

  late List<String> drops;
  late RxLogger logger;
  final validator = PacketValidator(allowedChannels: const {});

  setUp(() {
    drops = [];
    logger = RxLogger(
      onRxEntry: (_) async {},
      getGpsLocation: () =>
          (lat: 53.4903, lon: 8.0317, altitude: const FixAltitude.unknown()),
      onCarpeaterDrop: (id, _) => drops.add(id),
    );
    logger.startWardriving();
  });

  PacketMetadata packet(List<int> bytes) => PacketMetadata.fromRawPacket(
        raw: Uint8List.fromList(bytes),
        snr: 13.0,
        rssi: 0,
      );

  test('a direct packet never blames a hop on its route', () async {
    // Header 0x1E: route type 2 (direct), payload type ANON_REQ.
    final logged =
        await logger.handlePacket(packet([0x1E, ...pathAndPayload]), validator);
    expect(logged, isFalse);
    expect(drops, isEmpty);
  });

  test('a transport direct packet never blames a hop on its route', () async {
    // Header 0x1F: route type 3, with 4 transport code bytes before the path.
    final logged = await logger.handlePacket(
        packet([0x1F, 0x00, 0x00, 0x00, 0x00, ...pathAndPayload]), validator);
    expect(logged, isFalse);
    expect(drops, isEmpty);
  });

  test('a flood packet this strong still trips the carpeater failsafe',
      () async {
    // Header 0x1D: route type 1 (flood). Here the last hop really did send it.
    final logged =
        await logger.handlePacket(packet([0x1D, ...pathAndPayload]), validator);
    expect(logged, isFalse);
    expect(drops, ['850C']);
  });
}
