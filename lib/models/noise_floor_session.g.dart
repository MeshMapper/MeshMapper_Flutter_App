// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'noise_floor_session.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class NoiseFloorSampleAdapter extends TypeAdapter<NoiseFloorSample> {
  @override
  final int typeId = 10;

  @override
  NoiseFloorSample read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return NoiseFloorSample(
      timestamp: fields[0] as DateTime,
      noiseFloor: fields[1] as int,
    );
  }

  @override
  void write(BinaryWriter writer, NoiseFloorSample obj) {
    writer
      ..writeByte(2)
      ..writeByte(0)
      ..write(obj.timestamp)
      ..writeByte(1)
      ..write(obj.noiseFloor);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NoiseFloorSampleAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PingEventMarkerAdapter extends TypeAdapter<PingEventMarker> {
  @override
  final int typeId = 12;

  @override
  PingEventMarker read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return PingEventMarker(
      timestamp: fields[0] as DateTime,
      type: fields[1] as PingEventType,
      noiseFloor: fields[2] as int,
    );
  }

  @override
  void write(BinaryWriter writer, PingEventMarker obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.timestamp)
      ..writeByte(1)
      ..write(obj.type)
      ..writeByte(2)
      ..write(obj.noiseFloor);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PingEventMarkerAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class NoiseFloorSessionAdapter extends TypeAdapter<NoiseFloorSession> {
  @override
  final int typeId = 13;

  @override
  NoiseFloorSession read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return NoiseFloorSession(
      id: fields[0] as String,
      startTime: fields[1] as DateTime,
      endTime: fields[2] as DateTime?,
      mode: fields[3] as String,
      samples: (fields[4] as List?)?.cast<NoiseFloorSample>(),
      markers: (fields[5] as List?)?.cast<PingEventMarker>(),
    );
  }

  @override
  void write(BinaryWriter writer, NoiseFloorSession obj) {
    writer
      ..writeByte(6)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.startTime)
      ..writeByte(2)
      ..write(obj.endTime)
      ..writeByte(3)
      ..write(obj.mode)
      ..writeByte(4)
      ..write(obj.samples)
      ..writeByte(5)
      ..write(obj.markers);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is NoiseFloorSessionAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}

class PingEventTypeAdapter extends TypeAdapter<PingEventType> {
  @override
  final int typeId = 11;

  @override
  PingEventType read(BinaryReader reader) {
    switch (reader.readByte()) {
      case 0:
        return PingEventType.txSuccess;
      case 1:
        return PingEventType.txFail;
      case 2:
        return PingEventType.rx;
      case 3:
        return PingEventType.discSuccess;
      case 4:
        return PingEventType.discFail;
      default:
        return PingEventType.txSuccess;
    }
  }

  @override
  void write(BinaryWriter writer, PingEventType obj) {
    switch (obj) {
      case PingEventType.txSuccess:
        writer.writeByte(0);
        break;
      case PingEventType.txFail:
        writer.writeByte(1);
        break;
      case PingEventType.rx:
        writer.writeByte(2);
        break;
      case PingEventType.discSuccess:
        writer.writeByte(3);
        break;
      case PingEventType.discFail:
        writer.writeByte(4);
        break;
    }
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PingEventTypeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
