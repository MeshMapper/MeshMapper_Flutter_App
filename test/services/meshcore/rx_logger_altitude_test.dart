import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/services/fix_altitude.dart';
import 'package:mesh_mapper/services/meshcore/packet_metadata.dart';
import 'package:mesh_mapper/services/meshcore/packet_validator.dart';
import 'package:mesh_mapper/services/meshcore/rx_logger.dart';

/// An RX row keeps the altitude, reference and accuracy of the FIRST location
/// it was heard at, exactly as it keeps that location's coordinates, even when
/// a later, stronger observation replaces the SNR.

/// Accepts every packet. This test is about the location trio, not about
/// decryption, so the real validator (channel key, AES, printable ratio) is
/// bypassed; the logger's own pre-validator gates (flood route, a path) still
/// apply and these bytes pass them.
class _AcceptAll extends PacketValidator {
  _AcceptAll() : super(allowedChannels: const {});

  @override
  Future<ValidationResult> validate(PacketMetadata metadata,
          {bool skipRssiCheck = false}) async =>
      ValidationResult.success();
}

void main() {
  // The flood packet from rx_logger_direct_route_test.dart: header 0x1D,
  // path 7463 -> 850C (2 hops, 2 bytes each), then the payload. The last hop
  // 850C is the repeater credited.
  const packetBytes = [
    0x1D, 0x42, 0x74, 0x63, 0x85, 0x0C, 0xD1, 0x88, 0x9E, 0x55, 0x36, 0xCE, //
    0xFC, 0x27, 0x39, 0x6C, 0xE4, 0xE3, 0x05, 0xCF, 0x54, 0x91, 0x1C,
    0x87, 0x78, 0x51, 0xA6, 0xE4, 0x0A, 0x95, 0xA9, 0x8E, 0x78, 0x3D,
  ];

  PacketMetadata packet(double snr) => PacketMetadata.fromRawPacket(
        raw: Uint8List.fromList(packetBytes),
        snr: snr,
        rssi: -80,
      );

  test('the first location\'s altitude trio rides to the API entry', () async {
    final entries = <RxApiEntry>[];
    var fixes = 0;
    final logger = RxLogger(
      onRxEntry: (e) async => entries.add(e),
      getGpsLocation: () {
        fixes++;
        return fixes == 1
            ? (
                lat: 45.0,
                lon: -75.0,
                altitude: FixAltitude.known(
                    meters: 84.0,
                    reference: AltitudeReference.msl,
                    accuracy: 6.0),
              )
            : (lat: 45.1, lon: -75.1, altitude: const FixAltitude.unknown());
      },
    );
    logger.startWardriving();
    final validator = _AcceptAll();

    expect(await logger.handlePacket(packet(5.0), validator), isTrue);
    expect(await logger.handlePacket(packet(9.0), validator), isTrue,
        reason: 'better SNR, heard at a new fix');
    await logger.flushAllBatches();

    expect(entries, hasLength(1));
    final e = entries.single;
    expect(e.repeaterId, '850C');
    expect(e.snr, 9.0, reason: 'the better SNR wins');
    expect(e.lat, 45.0, reason: 'the FIRST location wins');
    expect(e.altitude.meters, 84.0);
    expect(e.altitude.reference, AltitudeReference.msl);
    expect(e.altitude.accuracy, 6.0);
  });

  test('an unknown altitude at the first fix stays unknown even when a later '
      'fix knew it', () async {
    final entries = <RxApiEntry>[];
    var fixes = 0;
    final logger = RxLogger(
      onRxEntry: (e) async => entries.add(e),
      getGpsLocation: () {
        fixes++;
        return fixes == 1
            ? (lat: 45.0, lon: -75.0, altitude: const FixAltitude.unknown())
            : (
                lat: 45.1,
                lon: -75.1,
                altitude: FixAltitude.known(
                    meters: 84.0, reference: AltitudeReference.msl),
              );
      },
    );
    logger.startWardriving();
    final validator = _AcceptAll();
    await logger.handlePacket(packet(5.0), validator);
    await logger.handlePacket(packet(9.0), validator);
    await logger.flushAllBatches();
    expect(entries.single.altitude.isKnown, isFalse);
  });
}
