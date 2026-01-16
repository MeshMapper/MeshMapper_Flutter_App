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
      deviceId: fields[4] as String,
      retryCount: fields[5] as int,
      lastRetryAt: fields[6] as DateTime?,
      power: fields[7] as int?,
      repeaterId: fields[8] as String?,
      snr: fields[9] as double?,
      rssi: fields[10] as int?,
    );
  }

  @override
  void write(BinaryWriter writer, ApiQueueItem obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.type)
      ..writeByte(1)
      ..write(obj.latitude)
      ..writeByte(2)
      ..write(obj.longitude)
      ..writeByte(3)
      ..write(obj.timestamp)
      ..writeByte(4)
      ..write(obj.deviceId)
      ..writeByte(5)
      ..write(obj.retryCount)
      ..writeByte(6)
      ..write(obj.lastRetryAt)
      ..writeByte(7)
      ..write(obj.power)
      ..writeByte(8)
      ..write(obj.repeaterId)
      ..writeByte(9)
      ..write(obj.snr)
      ..writeByte(10)
      ..write(obj.rssi);
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
