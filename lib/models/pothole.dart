import 'package:hive/hive.dart';

part 'pothole.g.dart';

@HiveType(typeId: 0)
class Pothole extends HiveObject {
  @HiveField(0)
  final String id;

  @HiveField(1)
  final String imagePath;

  @HiveField(2)
  final double latitude;

  @HiveField(3)
  final double longitude;

  @HiveField(4)
  final DateTime createdAt;

  @HiveField(5)
  String note;

  @HiveField(6)
  String status; // pending | sent | resolved

  @HiveField(7)
  final String detectedClass;

  @HiveField(8)
  final double confidence;

  @HiveField(9)
  final String address;

  Pothole({
    required this.id,
    required this.imagePath,
    required this.latitude,
    required this.longitude,
    required this.createdAt,
    this.note = '',
    this.status = 'pending',
    required this.detectedClass,
    required this.confidence,
    this.address = '',
  });
}
