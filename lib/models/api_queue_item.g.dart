// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'api_queue_item.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class ApiQueueItemAdapter extends TypeAdapter<ApiQueueItem> {
  @override
  final int typeId = 3;

  @override
  ApiQueueItem read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return ApiQueueItem(
      type: fields[0] as String,
      latitude: fields[1] as double,
      longitude: fields[2] as double,
      timestamp: fields[3] as DateTime,
      heardRepeats: fields[12] as String,
      retryCount: fields[5] as int,
      lastRetryAt: fields[6] as DateTime?,
      noiseFloor: fields[11] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, ApiQueueItem obj) {
    writer
      ..writeByte(8)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.latitude)
      ..writeByte(2)
      ..write(obj.longitude)
      ..writeByte(3)
      ..write(obj.timestamp)
      ..writeByte(5)
      ..write(obj.retryCount)
      ..writeByte(6)
      ..write(obj.lastRetryAt)
      ..writeByte(11)
      ..write(obj.noiseFloor)
      ..writeByte(12)
      ..write(obj.heardRepeats);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ApiQueueItemAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
