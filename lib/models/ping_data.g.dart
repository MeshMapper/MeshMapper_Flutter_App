// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'ping_data.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class TxPingAdapter extends TypeAdapter<TxPing> {
  @override
  final int typeId = 1;

  @override
  TxPing read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return TxPing(
      latitude: fields[0] as double,
      longitude: fields[1] as double,
      power: fields[2] as int,
      timestamp: fields[3] as DateTime,
      deviceId: fields[4] as String,
    );
  }

  @override
  void write(BinaryWriter writer, TxPing obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.latitude)
      ..writeByte(1)
      ..write(obj.longitude)
      ..writeByte(2)
      ..write(obj.power)
      ..writeByte(3)
      ..write(obj.timestamp)
      ..writeByte(4)
      ..write(obj.deviceId);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TxPingAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class RxPingAdapter extends TypeAdapter<RxPing> {
  @override
  final int typeId = 2;

  @override
  RxPing read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return RxPing(
      latitude: fields[0] as double,
      longitude: fields[1] as double,
      repeaterId: fields[2] as String,
      timestamp: fields[3] as DateTime,
      snr: fields[4] as double,
      rssi: fields[5] as int,
    );
  }

  @override
  void write(BinaryWriter writer, RxPing obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.latitude)
      ..writeByte(1)
      ..write(obj.longitude)
      ..writeByte(2)
      ..write(obj.repeaterId)
      ..writeByte(3)
      ..write(obj.timestamp)
      ..writeByte(4)
      ..write(obj.snr)
      ..writeByte(5)
      ..write(obj.rssi);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RxPingAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PingTypeAdapter extends TypeAdapter<PingType> {
  @override
  final int typeId = 0;

  @override
  PingType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return PingType.tx;
      case 1:
        return PingType.rx;
      default:
        return PingType.tx;
    }
  }

  @override
  void write(BinaryWriter writer, PingType obj) {
    switch (obj) {
      case PingType.tx:
        writer.writeByte(0);
        break;
      case PingType.rx:
        writer.writeByte(1);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PingTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
