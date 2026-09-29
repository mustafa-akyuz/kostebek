// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'pothole.dart';

// **************************************************************************
// TypeAdapterGenerator
// **************************************************************************

class PotholeAdapter extends TypeAdapter<Pothole> {
  @override
  final int typeId = 0;

  @override
  Pothole read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (int i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return Pothole(
      id: fields[0] as String,
      imagePath: fields[1] as String,
      latitude: fields[2] as double,
      longitude: fields[3] as double,
      createdAt: fields[4] as DateTime,
      note: fields[5] as String,
      status: fields[6] as String,
      detectedClass: fields[7] as String,
      confidence: fields[8] as double,
      address: fields[9] as String,
    );
  }

  @override
  void write(BinaryWriter writer, Pothole obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.imagePath)
      ..writeByte(2)
      ..write(obj.latitude)
      ..writeByte(3)
      ..write(obj.longitude)
      ..writeByte(4)
      ..write(obj.createdAt)
      ..writeByte(5)
      ..write(obj.note)
      ..writeByte(6)
      ..write(obj.status)
      ..writeByte(7)
      ..write(obj.detectedClass)
      ..writeByte(8)
      ..write(obj.confidence)
      ..writeByte(9)
      ..write(obj.address);
  }

  @override
  int get hashCode => typeId.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PotholeAdapter &&
          runtimeType == other.runtimeType &&
          typeId == other.typeId;
}
