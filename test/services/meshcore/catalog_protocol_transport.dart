import 'dart:async';
import 'dart:typed_data';

import 'package:mesh_mapper/services/meshcore/buffer_utils.dart';
import 'package:mesh_mapper/services/meshcore/crypto_service.dart';
import 'package:mesh_mapper/services/meshcore/protocol_constants.dart';

import 'fake_companion_transport.dart';

/// Responds with complete companion frames, leaving the real handshake intact.
class CatalogProtocolTransport extends FakeCompanionTransport {
  final String manufacturer;
  final String radioName;
  final Future<void> Function()? beforeSelfInfo;
  final bool failSelfInfo;
  CatalogProtocolTransport(
      {this.manufacturer = 'Tracker',
      this.radioName = 'Radio B',
      this.beforeSelfInfo,
      this.failSelfInfo = false});

  @override
  Future<void> write(Uint8List data) async {
    await super.write(data);
    final frame = BufferWriter();
    switch (data.first) {
      case CommandCodes.deviceQuery:
        frame.writeByte(ResponseCodes.deviceInfo);
        frame.writeByte(10);
        frame.writeBytes(Uint8List(6));
        frame.writeCString('14-Sep-2026', 12);
        frame.writeCString(manufacturer, 40);
        frame.writeCString('v1.14.0', 20);
        frame.writeByte(0);
        frame.writeByte(0);
      case CommandCodes.appStart:
        if (writes
                .where((frame) => frame.first == CommandCodes.appStart)
                .length ==
            2) {
          await beforeSelfInfo?.call();
        }
        if (failSelfInfo) {
          emit([ResponseCodes.err, 1]);
          return;
        }
        frame.writeByte(ResponseCodes.selfInfo);
        frame.writeByte(1);
        frame.writeByte(22);
        frame.writeByte(22);
        frame.writeBytes(Uint8List.fromList(List.filled(32, 0x42)));
        frame.writeBytes(Uint8List(12));
        frame.writeUInt32LE(910525);
        frame.writeUInt32LE(62500);
        frame.writeByte(7);
        frame.writeByte(5);
        frame.writeString(radioName);
      case CommandCodes.setDeviceTime:
        frame.writeByte(ResponseCodes.ok);
      case CommandCodes.getChannel:
        if (data[1] > 0) {
          emit([ResponseCodes.err, 1]);
          return;
        }
        frame.writeByte(ResponseCodes.channelInfo);
        frame.writeByte(0);
        frame.writeCString('#wardriving', 32);
        frame.writeBytes(CryptoService.deriveChannelKey('#wardriving'));
      case CommandCodes.getBatteryVoltage:
        frame.writeByte(ResponseCodes.batteryVoltage);
        frame.writeUInt32LE(4000);
      case CommandCodes.getStats:
        frame.writeByte(ResponseCodes.stats);
        frame.writeByte(StatsTypes.radio);
        frame.writeBytes(Uint8List(12));
      default:
        throw StateError('Unexpected handshake command: ${data.first}');
    }
    emit(frame.toBytes());
  }
}
