import 'dart:io';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/pothole.dart';

class DatabaseService {
  static const String _boxName = 'potholes';
  static late Box<Pothole> _box;

  static Future<void> init() async {
    try {
      await Hive.initFlutter();
      if (!Hive.isAdapterRegistered(0)) {
        Hive.registerAdapter(PotholeAdapter());
      }
      _box = await Hive.openBox<Pothole>(_boxName);
    } catch (e) {
      print('[DatabaseService] Init hatasi: $e');
      rethrow;
    }
  }

  static Future<void> add(Pothole p) async {
    try {
      await _box.put(p.id, p);
    } catch (e) {
      print('[DatabaseService] Ekleme hatasi: $e');
      rethrow;
    }
  }

  static List<Pothole> getAll() {
    final list = _box.values.toList();
    list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return list;
  }

  static Pothole? getById(String id) => _box.get(id);

  static Future<void> update(Pothole p) async {
    try {
      await _box.put(p.id, p);
    } catch (e) {
      print('[DatabaseService] Guncelleme hatasi: $e');
      rethrow;
    }
  }

  static Future<void> delete(String id, {bool deleteFile = true}) async {
    try {
      if (deleteFile) {
        final item = _box.get(id);
        if (item != null && item.imagePath.isNotEmpty) {
          try {
            final f = File(item.imagePath);
            if (f.existsSync()) {
              await f.delete();
            }
          } catch (_) {}
        }
      }
      await _box.delete(id);
    } catch (e) {
      print('[DatabaseService] Silme hatasi: $e');
      rethrow;
    }
  }

  static Future<void> deleteAll() async {
    try {
      for (final item in _box.values) {
        if (item.imagePath.isNotEmpty) {
          try {
            final f = File(item.imagePath);
            if (f.existsSync()) {
              await f.delete();
            }
          } catch (_) {}
        }
      }
      await _box.clear();
    } catch (e) {
      print('[DatabaseService] Tumunu silme hatasi: $e');
      rethrow;
    }
  }

  static int count() => _box.length;

  static int pendingCount() =>
      _box.values.where((p) => p.status == 'pending').length;
}
